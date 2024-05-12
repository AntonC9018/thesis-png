const common = @import("common.zig");
const std = common.std;
const zlib = common.zlib;
const pipelines = common.pipelines;

const Context = common.Context;

pub fn readNullTerminatedText(
    context: *Context,
    output: *std.ArrayListUnmanaged(u8),
    maxLenExcludingNull: usize) !void
{
    const sequence = context.sequence();

    if (output.items.len == maxLenExcludingNull)
    {
        return;
    }

    var iter = sequence.iterate() orelse return error.NotEnoughBytes;

    while (true)
    {
        const slice = iter.current();
        const bytesLeftToRead = maxLenExcludingNull - output.items.len;
        const maxBytesWillRead = @min(slice.len, bytesLeftToRead);

        const nullBytePos = n:
        {
            // +1 because the null termination might be outside the bytes of the string.
            for (0 .. maxBytesWillRead + 1) |i|
            {
                const byte = slice[i];
                if (byte == 0)
                {
                    break :n i;
                }
            }
            break :n null;
        };

        if (nullBytePos == null)
        {
            // Just this is fine by itself if the null byte is in the next segment.
            if (maxBytesWillRead == bytesLeftToRead
                and maxBytesWillRead < slice.len)
            {
                // TODO: Should we consume the bytes still in case of error?
                return error.ExpectedNullByteAtEndOfString;
            }

            // We were only looking for the last null byte on this iteration,
            // but didn't find it.
            if (maxBytesWillRead == 0)
            {
                return error.ExpectedNullByteAtEndOfString;
            }
        }

        const copyUntilPos = nullBytePos orelse maxBytesWillRead;
        const sourceSlice = slice[0 .. copyUntilPos];

        const containsConsecutiveOrLeadingSpaces = sp:
        {
            if (copyUntilPos == 0)
            {
                break :sp false;
            }

            if (output.items.len == 0)
            {
                if (slice[0] == ' ')
                {
                    break :sp true;
                }
            }
            else
            {
                var isPreviousSpace = output.items[output.items.len - 1] == ' ';
                for (sourceSlice) |byte|
                {
                    const isSpace = byte == ' ';
                    if (isSpace and isPreviousSpace)
                    {
                        break :sp true;
                    }
                    isPreviousSpace = isSpace;
                }
            }

            break :sp false;
        };
        const nonPrintableCharacterIndex = ch:
        {
            for (0 .., sourceSlice) |i, byte|
            {
                switch (byte)
                {
                    ' ' ... '~' => {},
                    161 ... 255 => {},
                    else => break :ch i,
                }
            }
            break :ch null;
        };

        const anyError = containsConsecutiveOrLeadingSpaces or nonPrintableCharacterIndex != null;
        if (anyError)
        {
            const offset = offset:
            {
                if (containsConsecutiveOrLeadingSpaces)
                {
                    break :offset 0;
                }
                if (nonPrintableCharacterIndex) |i|
                {
                    break :offset i;
                }
                unreachable;
            };

            const newStart = iter.getCurrentPosition().add(@intCast(offset));
            sequence.* = sequence.sliceFrom(newStart);

            if (containsConsecutiveOrLeadingSpaces)
            {
                return error.ContainsConsecutiveOrLeadingSpaces;
            }
            if (nonPrintableCharacterIndex != null)
            {
                return error.NonPrintableCharacter;
            }
        }

        if (copyUntilPos > 0)
        {
            const destinationSlice = try output.addManyAsSlice(context.allocator(), copyUntilPos);
            @memcpy(destinationSlice, sourceSlice);
        }

        if (nullBytePos) |readUntilPos|
        {
            // We want to consume the null termination as well.
            const newStart = iter.getCurrentPosition().add(@intCast(readUntilPos + 1));
            // Update the sequence to this position.
            sequence.* = sequence.sliceFrom(newStart);
            return;
        }

        if (!iter.advance())
        {
            sequence.* = sequence.sliceFrom(sequence.end());
            return error.NotEnoughBytes;
        }
    }
}

pub fn readZlibData(
    context: *Context,
    state: *zlib.State,
    output: *std.ArrayListUnmanaged(u8)) !bool
{
    // Maybe wrap the zlib stream.
    try context.level().pushNode(.ZlibContainer);
    defer context.level().pop();

    var outputBuffer = zlib.OutputBuffer
    {
        .allocator = context.allocator(),
        .array = output,
        .windowSize = &state.windowSize,
    };
    var c = zlib.CommonContext
    {
        .common = context.common,
        .output = &outputBuffer,
    };
    var zlibContext = zlib.Context
    {
        .common = &c,
        .state = state,
    };
    const isDone = try zlib.decode(&zlibContext);
    if (isDone)
    {
        try context.level().completeNode();
        return true;
    }
    return false;
}

pub fn removeAndProcessNextByte(
    context: *Context,
    functor: anytype) !bool
{
    if (context.sequence().len() == 0)
    {
        std.debug.assert(!context.isLastChunkSequenceSlice);
        return error.NotEnoughBytes;
    }

    try functor.pushLevels();
    
    const front = try pipelines.removeFirst(context.sequence());

    try functor.each(front);

    return context.sequence().len() == 0 and context.isLastChunkSequenceSlice;
}

pub fn removeAndProcessAsManyBytesAsAvailable(
    context: *Context,
    // Must have a function each that takes in the byte.
    // Can have an optional function init that takes the count.
    functor: anytype) !bool
{
    const sequenceLen = context.sequence().len();
    if (sequenceLen == 0)
    {
        std.debug.assert(!context.isLastChunkSequenceSlice);
        return error.NotEnoughBytes;
    }

    const bytesThatWillBeRead = sequenceLen;

    if (@hasDecl(@TypeOf(functor), "initCount"))
    {
        try functor.initCount(bytesThatWillBeRead);
    }

    const sequence = context.sequence().*;
    context.sequence().* = sequence.sliceFrom(sequence.end());

    if (@hasDecl(@TypeOf(functor), "sequence"))
    {
        try functor.sequence(sequence);
    }

    if (@hasDecl(@TypeOf(functor), "each"))
    {
        var iter = pipelines.SegmentIterator.create(&sequence).?;
        while (true)
        {
            const slice = iter.current();
            for (slice) |byte|
            {
                try functor.each(byte);
            }
            if (!iter.advance())
            {
                break;
            }
        }
    }

    return context.isLastChunkSequenceSlice;
}

pub fn readPngU32(sequence: *pipelines.Sequence) !u32
{
    const value = try pipelines.readNetworkUnsigned(sequence, u32);
    if (value > 0x80000000)
    {
        return error.UnsignedValueTooLarge;
    }
    return value;
}

pub fn readPngU32Dimension(sequence: *pipelines.Sequence) !u32
{
    const value = readPngU32(sequence)
    catch
    {
        return error.DimensionValueTooLarge;
    };
    if (value == 0)
    {
        return error.DimensionValueIsZero;
    }
    return value;
}

pub fn readKeywordText(
    context: *Context,
    keyword: *std.ArrayListUnmanaged(u8)) !void
{
    const maxLen = 80;
    try readNullTerminatedText(context, keyword, maxLen);
}
