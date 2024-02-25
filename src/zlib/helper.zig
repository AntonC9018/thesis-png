pub const pipelines = @import("../pipelines.zig");
pub const DeflateContext = @import("zlib.zig").DeflateContext;
pub const std = @import("std");
pub const huffman = @import("huffmanTree.zig");

pub const PeekApplyHelper = struct
{
    nextBitOffset: u4,
    nextSequenceStart: pipelines.SequencePosition,

    pub fn apply(self: PeekApplyHelper, context: *DeflateContext) void
    {
        context.state.bitOffset = self.nextBitOffset;
        context.sequence.* = context.sequence.sliceFrom(self.nextSequenceStart);
    }
};

pub fn PeekNBitsResult(resultType: type) type
{
    return struct
    {
        bits: resultType,
        applyHelper: PeekApplyHelper,

        const Self = @This();

        pub fn apply(self: Self, context: *DeflateContext) void
        {
            self.applyHelper.apply(context);
        }
    };
}

pub const PeekNBitsContext = struct
{
    context: *const DeflateContext,
    bitsCount: u6,
    comptime reverse: bool = false,

    fn sequence(self: *PeekNBitsContext) *const pipelines.Sequence
    {
        return self.context.sequence;
    }

    fn bitOffset(self: *PeekNBitsContext) u4
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

    var bitOffset = context.state.bitOffset;
    var bitsRead = 0;
    var result: ResultType = 0;

    var iterator = pipelines.SegmentIterator.create(context.sequence()).?;
    while (bitsRead < context.bitsCount)
    {
        const byte = iterator.current();
        const availableByteBitCount = 8 - bitOffset;
        const byteBits = byte >> bitOffset;

        const bitCountLeftToRead = context.bitsCount - bitsRead;
        const bitCountWillRead = @min(bitCountLeftToRead, availableByteBitCount);
        bitOffset = (bitOffset + bitCountWillRead) % 8;

        const willReadMask = 0xFF >> (8 - bitCountWillRead);
        const readBits_ = byteBits & willReadMask;
        const readBitsAsResultType: ResultType = @intCast(readBits_);

        if (context.reverse)
        {
            const c = context.bitsCount - bitsRead - 1;
            for (0 .. bitCountWillRead) |i|
            {
                const bit = (readBitsAsResultType >> i) & 1;
                result |= bit << (c + i);
            }
        }
        else
        {
            result |= readBitsAsResultType << bitsRead;
        }

        bitsRead += bitCountWillRead;

        if (bitCountWillRead >= availableByteBitCount)
        {
            const advanced = iterator.advance();
            std.debug.assert(advanced);
        }
    }

    return .{
        .bits = result,
        .applyHelper = .{
            .nextBitOffset = bitOffset,
            .nextSequenceStart = iterator.sequence.start(),
        },
    };
}

pub fn peekBits(context: *DeflateContext, ResultType: type)
    !PeekNBitsResult(ResultType)
{
    const bitsCount = comptime b:
    {
        const typeInfo = @typeInfo(ResultType);
        const bitsCount: u4 = @intCast(typeInfo.Int.bits);
        break :b bitsCount;
    };

    std.debug.assert(bitsCount <= 32 and bitsCount > 0);

    return @intCast(peekNBits(.{
        .context = context,
        .bitsCount = bitsCount
    }));
}

pub fn readBits(context: *DeflateContext, ResultType: type) !ResultType
{
    const r = try peekBits(context, ResultType);
    r.apply(context);
    return r.bits;
}

pub fn readNBits(context: *DeflateContext, bitsCount: u6) !u32
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
    huffman_: *HuffmanParsingState,

    pub fn apply(self: *DecodedCharacterResult, context: *DeflateContext) void
    {
        self.applyHelper.apply(context);
        self.huffman_.currentBitCount = 0;
    }
};

pub fn readAndDecodeCharacter(context: *DeflateContext, huffman_: *HuffmanParsingState) !u16
{
    const r = try peekAndDecodeCharacter(context, huffman_);
    r.apply(context, huffman_);
    return r.character;
}

pub fn peekAndDecodeCharacter(context: *const DeflateContext, huffman_: *HuffmanParsingState) !DecodedCharacterResult
{
    if (huffman_.currentBitCount == 0)
    {
        huffman_.currentBitCount = huffman_.tree.getNextBitCount(0);
    }

    while (true)
    {
        const code = try peekNBits(.{
            .context = context,
            .bitsCount = huffman_.currentBitCount,
            .reverse = true,
        });
        const decoded = try huffman_.tree.tryDecode(code.bits, huffman_.currentBitCount);
        switch (decoded)
        {
            .DecodedCharacter => |ch|
            {
                return ch;
            },
            .NextBitCount => |bitCount|
            {
                huffman_.currentBitCount = bitCount;
            },
        }
    }
}

const HuffmanParsingState = struct
{
    tree: huffman.Tree,
    currentBitCount: u5,
};

fn readArrayElement(
    context: *DeflateContext,
    array: anytype, 
    currentNumberOfElements: *usize,
    bitsCount: u5) !bool
{
    if (currentNumberOfElements.* < array.len)
    {
        const value = try readNBits(context, bitsCount);
        array[currentNumberOfElements.*] = value;
        currentNumberOfElements.* += 1;
    }
    if (currentNumberOfElements.* == array.len)
    {
        currentNumberOfElements.* = 0;
        return true;
    }
    return false;
}

pub const OutputBuffer = struct
{
    position: usize,
    len: usize,

    pub fn writeByte(self: *OutputBuffer, byte: u8) !void
    {
        _ = self;
        _ = byte;
        unreachable;
    }

    pub fn writeBytes(self: *OutputBuffer, buffer: []const u8) !void
    {
        _ = self;
        _ = buffer;
        unreachable;
    }

    pub fn referBack(self: *const OutputBuffer, byteOffset: usize) u8
    {
        std.debug.assert(byteOffset < 32 * 1024);

        _ = self;
        unreachable;
    }

    pub fn copyFromSelf(self: *OutputBuffer, length: usize, distance: usize) !void
    {
        for (0 .. length) |_|
        {
            const byte = self.referBack(distance);
            try self.writeByte(byte);
        }
        unreachable;
    }
};
