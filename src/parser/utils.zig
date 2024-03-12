const common = @import("common.zig");
const std = common.std;
const zlib = common.zlib;
const pipelines = common.pipelines;

pub fn readNullTerminatedText(
    context: *const common.Context,
    output: *std.ArrayListUnmanaged(u8),
    maxLenExcludingNull: usize) !void
{
    const sequence = context.sequence;

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
            const destinationSlice = try output.addManyAsSlice(context.allocator, copyUntilPos);
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
    context: anytype,
    state: *zlib.State,
    output: *std.ArrayListUnmanaged(u8)) !bool
{
    var outputBuffer = zlib.OutputBuffer
    {
        .allocator = context.allocator,
        .array = output,
        .windowSize = &state.windowSize,
    };
    const c = zlib.CommonContext
    {
        .allocator = context.allocator,
        .output = &outputBuffer,
        .sequence = context.sequence,
    };
    const zlibContext = zlib.Context
    {
        .common = &c,
        .state = state,
    };
    const isDone = try zlib.decode(&zlibContext);
    if (isDone)
    {
        return true;
    }
    return false;
}

pub fn removeAndProcessAsManyBytesAsAvailable(
    context: *const common.Context,
    bytesRead: *u32,
    // Must have a function each that takes in the byte.
    // Can have an optional function init that takes the count.
    functor: anytype) !bool
{
    const totalBytes = context.state.chunk.object.dataByteLen;
    std.debug.assert(bytesRead.* <= totalBytes);

    if (bytesRead.* == totalBytes)
    {
        return true;
    }

    const sequenceLength = context.sequence.len();
    if (sequenceLength == 0)
    {
        return error.NotEnoughBytes;
    }

    const maxBytesToRead = totalBytes - bytesRead.*;
    const bytesThatWillBeRead: u32 = @intCast(@min(maxBytesToRead, sequenceLength));
    const readPosition = context.sequence.getPosition(bytesThatWillBeRead);
    const s = context.sequence.disect(readPosition);

    if (@hasDecl(@TypeOf(functor), "initCount"))
    {
        try functor.initCount(bytesThatWillBeRead);
    }

    bytesRead.* += bytesThatWillBeRead;
    context.sequence.* = s.right;

    if (@hasDecl(@TypeOf(functor), "sequence"))
    {
        try functor.sequence(s.left);
    }

    if (@hasDecl(@TypeOf(functor), "each"))
    {
        var iter = pipelines.SegmentIterator.create(&s.left).?;
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

    return (bytesRead.* == totalBytes);
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

pub fn skipBytes(context: *const common.Context, chunk: *common.ChunkState) !bool
{
    const bytesSkipped = &chunk.dataState.bytesSkipped;
    const totalBytes = chunk.object.dataByteLen;

    std.debug.assert(bytesSkipped.* <= totalBytes);

    if (bytesSkipped.* < totalBytes)
    {
        const bytesLeftToSkip = totalBytes - bytesSkipped.*;
        const bytesToSkipNowCount = @min(bytesLeftToSkip, context.sequence.len());
        if (bytesToSkipNowCount == 0)
        {
            return error.NotEnoughBytes;
        }
        bytesSkipped.* += @intCast(bytesToSkipNowCount);

        const newStart = context.sequence.getPosition(bytesToSkipNowCount);
        context.sequence.* = context.sequence.sliceFrom(newStart);
    }

    return (bytesSkipped.* == totalBytes);
}

pub fn readKeywordText(
    context: *const common.Context,
    keyword: *std.ArrayListUnmanaged(u8),
    bytesRead: *u32) !void
{
    const maxLen = 80;
    try readNullTerminatedText(context, keyword, maxLen);
    // TODO: This is kind of dumb. It should be kept track of at a higher level.
    bytesRead.* = @intCast(keyword.items.len + 1);
}
