pub const pipelines = @import("../pipelines.zig");
pub const DeflateContext = @import("deflate.zig").Context;
pub const std = @import("std");
pub const huffman = @import("huffmanTree.zig");

pub const PeekApplyHelper = struct
{
    nextBitOffset: u3,
    nextSequenceStart: pipelines.SequencePosition,

    pub fn apply(self: PeekApplyHelper, context: *const DeflateContext) void
    {
        context.state.bitOffset = self.nextBitOffset;
        context.sequence().* = context.sequence().sliceFrom(self.nextSequenceStart);
    }
};

pub fn PeekNBitsResult(resultType: type) type
{
    return struct
    {
        bits: resultType,
        applyHelper: PeekApplyHelper,

        const Self = @This();

        pub fn apply(self: Self, context: *const DeflateContext) void
        {
            self.applyHelper.apply(context);
        }
    };
}

pub const PeekNBitsContext = struct
{
    context: *const DeflateContext,
    bitsCount: u6,
    reverse: bool = false,

    fn sequence(self: *const PeekNBitsContext) *const pipelines.Sequence
    {
        return self.context.sequence();
    }

    fn bitOffset(self: *const PeekNBitsContext) u3
    {
        return self.context.state.bitOffset;
    }
};

pub fn peekNBits(context: PeekNBitsContext) !PeekNBitsResult(u32)
{
    const ResultType = u32;
    const len = context.sequence().len();
    if (len == 0)
    {
        return error.NotEnoughBytes;
    }

    const availableBits = len * 8 - context.bitOffset();
    if (availableBits < context.bitsCount)
    {
        return error.NotEnoughBytes;
    }

    var bitOffset = context.bitOffset();
    var bitsRead: u5 = 0;
    var result: ResultType = 0;

    var iterator = pipelines.SegmentIterator.create(context.sequence()).?;
    const newPosition = newStart: while (true)
    {
        const slice = iterator.current();
        for (0 .., slice) |byteIndex, byte|
        {
            const availableByteBitCount: u4 = @intCast(@as(u8, 8) - @as(u8, bitOffset));
            const byteBits = byte >> bitOffset;

            const bitCountLeftToRead = context.bitsCount - bitsRead;
            const bitCountWillRead = @min(bitCountLeftToRead, availableByteBitCount);
            bitOffset = @intCast((@as(u8, bitOffset) + @as(u8, bitCountWillRead)) % 8);
            
            const willReadMask = @as(u8, 0xFF) >> @intCast(@as(u8, 8) - @as(u8, bitCountWillRead));
            const readBits_ = byteBits & willReadMask;
            const readBitsAsResultType: ResultType = @intCast(readBits_);

            if (context.reverse)
            {
                const c = context.bitsCount - bitsRead - 1;
                for (0 .. bitCountWillRead) |i|
                {
                    const bit = (readBitsAsResultType >> @intCast(i)) & 1;
                    result |= bit << @intCast(c + i);
                }
            }
            else
            {
                result |= readBitsAsResultType << bitsRead;
            }

            bitsRead += bitCountWillRead;

            if (bitsRead == context.bitsCount)
            {
                break :newStart iterator.currentPosition.add(@intCast(byteIndex + 1));
            }
        }

        const advanced = iterator.advance();
        std.debug.assert(advanced);
    };

    return .{
        .bits = result,
        .applyHelper = .{
            .nextBitOffset = bitOffset,
            .nextSequenceStart = newPosition,
        },
    };
}

pub fn peekBits(context: *const DeflateContext, ResultType: type)
    !PeekNBitsResult(ResultType)
{
    const bitsCount = comptime b:
    {
        const typeInfo = @typeInfo(ResultType);
        const bitsCount: u4 = @intCast(typeInfo.Int.bits);
        break :b bitsCount;
    };

    std.debug.assert(bitsCount <= 32 and bitsCount > 0);

    const result = try peekNBits(.{
        .context = context,
        .bitsCount = bitsCount,
    });

    return .{
        .bits = @intCast(result.bits),
        .applyHelper = result.applyHelper,
    };
}

pub fn readBits(context: *const DeflateContext, ResultType: type) !ResultType
{
    const r = try peekBits(context, ResultType);
    r.apply(context);
    return r.bits;
}

pub fn readNBits(context: *const DeflateContext, bitsCount: u6) !u32
{
    const r = try peekNBits(.{
        .context = context,
        .bitsCount = bitsCount,
    });
    r.apply(context);
    return @intCast(r.bits);
}

pub const DecodedCharacterResult = struct
{
    character: huffman.DecodedCharacter,
    applyHelper: PeekApplyHelper,
    currentBitCount: *u5,

    pub fn apply(self: *const DecodedCharacterResult, context: *const DeflateContext) void
    {
        self.applyHelper.apply(context);
        self.currentBitCount.* = 0;
    }
};

pub fn readAndDecodeCharacter(context: *const DeflateContext, huffman_: HuffmanContext) !u16
{
    const r = try peekAndDecodeCharacter(context, huffman_);
    r.apply(context);
    return r.character;
}

fn peekAndDecodeCharacter(context: *const DeflateContext, huffman_: HuffmanContext) !DecodedCharacterResult
{
    if (huffman_.currentBitCount.* == 0)
    {
        huffman_.currentBitCount.* = huffman_.tree.getInitialBitCount();
    }

    while (true)
    {
        const code = try peekNBits(.{
            .context = context,
            .bitsCount = huffman_.currentBitCount.*,
            .reverse = true,
        });
        const decoded = try huffman_.tree.tryDecode(
            @intCast(code.bits),
            huffman_.currentBitCount.*);
        switch (decoded)
        {
            .DecodedCharacter => |ch|
            {
                return .{
                    .character = ch,
                    .applyHelper = code.applyHelper,
                    .currentBitCount = huffman_.currentBitCount,
                };
            },
            .NextBitCount => |bitCount|
            {
                huffman_.currentBitCount.* = bitCount;
            },
        }
    }
}

pub const HuffmanContext = struct
{
    tree: *huffman.Tree,
    // Could make this store the currently read number as well if needed for optimization.
    // Adding on just a single bit is easier than rereading the whole thing.
    // So this ideally should be wrapped in a HuffamState sort of struct.
    currentBitCount: *u5,
};

pub fn readArrayElement(
    context: *const DeflateContext,
    array: anytype, 
    currentNumberOfElements: *usize,
    bitsCount: u5) !bool
{
    if (currentNumberOfElements.* < array.len)
    {
        const value = try readNBits(context, bitsCount);
        array[currentNumberOfElements.*] = @intCast(value);
        currentNumberOfElements.* += 1;
    }
    if (currentNumberOfElements.* == array.len)
    {
        currentNumberOfElements.* = 0;
        return true;
    }
    return false;
}

pub const CommonContext = struct
{
    sequence: *pipelines.Sequence,
    allocator: std.mem.Allocator,
    output: *OutputBuffer,
};

pub const OutputBuffer = struct
{
    buffer: []u8,
    position: usize,
    windowSize: usize,

    pub fn setWindowSize(self: *OutputBuffer, windowSize: usize) void
    {
        self.windowSize = windowSize;
    }

    pub fn deinit(self: *OutputBuffer, allocator: std.mem.Allocator) void
    {
        allocator.free(self.buffer);
    }

    pub fn writeByte(self: *OutputBuffer, byte: u8) !void
    {
        self.buffer[self.position] = byte;
        self.position += 1;
    }

    pub fn writeBytes(self: *OutputBuffer, buffer: []const u8) !void
    {
        const start = self.position;
        const end = start + buffer.len;
        for (self.buffer[start .. end], buffer) |*dest, source|
        {
            dest.* = source;
        }
        self.position = end;
    }

    pub fn copyFromSelf(self: *OutputBuffer, backRef: BackReference) !void
    {
        if (self.buffer.len < backRef.distance)
        {
            return error.BackReferenceDistanceTooLarge;
        }

        if (backRef.distance == 0)
        {
            return error.BackReferenceDistanceIsZero;
        }

        // NOTE: the memory can overlap here.
        for (0 .. backRef.len) |_|
        {
            const byte = self.buffer[self.position - backRef.distance];
            self.buffer[self.position] = byte;
            self.position += 1;
        }
    }
};

pub const BackReference = struct
{
    distance: u16,
    len: u16,
};

pub const Symbol = union(enum)
{
    endBlock: void,
    literalValue: u8,
    backReference: BackReference,
};

pub fn writeSymbolToOutput(context: *const DeflateContext, symbol: ?Symbol) !bool
{
    if (symbol) |s|
    {
        const done = try writeSymbolToOutput_switch(context, s);
        if (done)
        {
            context.state.action = .Done;
            return true;
        }
    }
    return false;
}

fn writeSymbolToOutput_switch(context: *const DeflateContext, symbol: Symbol) !bool
{
    switch (symbol)
    {
        .endBlock =>
        {
            return true;
        },
        .literalValue => |literal|
        {
            try context.output().writeByte(literal);
        },
        .backReference => |backReference|
        {
            try context.output().copyFromSelf(backReference);
        },
    }
    return false;
}

