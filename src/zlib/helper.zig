pub const pipelines = @import("../pipelines.zig");
pub const DeflateContext = @import("zlib.zig").DeflateContext;
pub const std = @import("std");
pub const huffman = @import("huffmanTree.zig");

pub fn PeekNBitsResult(resultType: type) type
{
    return struct
    {
        bits: resultType,
        nextBitOffset: u4,
        nextSequenceStart: pipelines.SequencePosition,

        const Self = @This();

        pub fn apply(self: Self, context1: *DeflateContext) void
        {
            context1.state.bitOffset = self.nextBitOffset;
            context1.sequence.* = context1.sequence.sliceFrom(self.nextSequenceStart);
        }
    };
}

pub fn peekNBits(context: *DeflateContext, bitsCount: u6) u32
    !PeekNBitsResult(u32)
{
    const ResultType = u16;
    const len = context.sequence.len();
    if (len == 0)
    {
        return error.NotEnoughBytes;
    }

    const availableBits = len * 8 - context.state.bitOffset;
    if (availableBits < bitsCount)
    {
        return error.NotEnoughBytes;
    }

    var bitOffset = context.state.bitOffset;
    var bitsRead = 0;
    var result: ResultType = 0;

    var iterator = pipelines.SegmentIterator.create(context.sequence).?;
    while (bitsRead < bitsCount)
    {
        const byte = iterator.current();
        const availableByteBitCount = 8 - bitOffset;
        const byteBits = byte >> bitOffset;

        const bitCountLeftToRead = bitsCount - bitsRead;
        const bitCountWillRead = @min(bitCountLeftToRead, availableByteBitCount);
        bitOffset = (bitOffset + bitCountWillRead) % 8;

        const willReadMask = 0xFF >> (8 - bitCountWillRead);
        const readBits_ = byteBits & willReadMask;
        const readBitsAsResultType: ResultType = @intCast(readBits_);
        result |= readBitsAsResultType << bitsRead;
        bitsRead += bitCountWillRead;

        if (bitCountWillRead >= availableByteBitCount)
        {
            const advanced = iterator.advance();
            std.debug.assert(advanced);
        }
    }

    return .{
        .bits = result,
        .nextBitOffset = bitOffset,
        .nextSequenceStart = iterator.sequence.start(),
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

    return @intCast(peekNBits(context, bitsCount));
}

pub fn readBits(context: *DeflateContext, ResultType: type) !ResultType
{
    const r = try peekBits(context, ResultType);
    r.apply(context);
    return r.bits;
}

pub fn readNBits(context: *DeflateContext, bitCount: u6) !u32
{
    const r = try peekNBits(context, bitCount);
    r.apply(context);
    return @intCast(r.bits);
}

pub fn readAndDecodeCharacter(context: *DeflateContext, huffman_: *HuffmanParsingState) !u16
{
    if (huffman_.currentBitCount == 0)
    {
        huffman_.currentBitCount = huffman_.tree.getNextBitCount(0);
    }

    while (true)
    {
        const code = try peekNBits(context, huffman_.currentBitCount);
        const decoded = try huffman_.tree.tryDecode(@intCast(code.bits), huffman_.currentBitCount);
        switch (decoded)
        {
            .DecodedCharacter => |ch|
            {
                code.apply(context);
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

