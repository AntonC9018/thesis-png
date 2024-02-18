const std = @import("std");
const pipelines = @import("pipelines.zig");

const ZlibHeader = struct
{
    compressionMethod: CompressionMethodAndFlags,
    flags: Flags,
    dictionaryId: u4,
};

const ZlibState = struct
{
    // Adler-32 checksum
    checksum: u32,
};

const CompressionMethodAndFlags = packed struct
{
    compressionMethod: CompressionMethod,
    compressionInfo: CompressionInfo,

    // value: u8,

    // pub fn compressionMethod(self: CompresssionMethodAndFlags) CompressionMethod
    // {
    //     return @enumFromInt(value & 0x0F);
    // }
    // pub fn compressionInfo(self: CompressionMethodAndFlags) Flags
    // {
    //     return @enumFromInt((value >> 4) & 0x0F);
    // }
    // pub fn setCompressionMethod(
    //     self: *CompresssionMethodAndFlags,
    //     compressionMethod: CompressionMethod) void
    // {
    //     self.value = (self.value & 0xF0) | @intFromEnum(compressionMethod);
    // }
    // pub fn setCompressionInfo(
    //     self: *CompresssionMethodAndFlags,
    //     flags: Flags) void
    // {
    //     self.value = (self.value & 0x0F) | (@intFromEnum(flags) << 4);
    // }
};

const CompressionMethod = enum(u4)
{
    Deflate = 8,
    Reserved = 15,
};

const CompressionInfo = u4;

const Flags = packed struct
{
    check: u4,
    presetDictionary: bool,
    compressionLevel: CompressionLevel,
};

const CompressionLevel = enum(u3)
{
    Fastest = 0,
    Fast = 1,
    Default = 2,
    SlowMaximumCompression = 3,
};

const PresetDictionary = struct {};

fn checkCheckFlag(cmf: CompressionMethodAndFlags, flags: Flags) bool
{
    const cmfByte: u8 = @bitCast(cmf);
    const flagsByte: u8 = @bitCast(flags);
    const value: u16 = (cmfByte << 8) | flagsByte;
    const remainder = value % 31;
    return remainder == 0;
}

const BlockType = enum(u2)
{
    NoCompression = 0,
    FixedHuffman = 1,
    DynamicHuffman = 2,
    Reserved = 3,
};

const DeflateContext = struct
{
    sequence: *pipelines.Sequence,
    state: *DeflateState,
};

const DeflateState = struct
{
    key: DeflateStateKey,
    bitOffset: u4,
    isFinal: bool,
    blockType: BlockType,
    len: u16,
    dataBytesRead: u16,
};

const DeflateStateKey = enum
{
    IsFinal,
    BlockType,

    NoCompressionLen,
    NoCompressionNLen,
    UncompressedBytes,
};

pub fn readNBits(context: *DeflateContext, resultType: anytype) !resultType
{
    const bitsCount = comptime b:
    {
        const typeInfo = @typeInfo(resultType);
        const bitsCount: u4 = @intCast(typeInfo.Int.bits);
        std.debug.assert(bitsCount <= 8);
        break :b bitsCount;
    };

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

    const bitOffset = &context.state.bitOffset;
    const firstByteBitsLeft = 8 - bitOffset.*;

    const s = context.sequence;
    const firstByte = s.peekFirstByte().?;
    const mask = 0xFF >> (8 - bitsCount);
    const firstByteBits = (firstByte >> bitOffset.*) & mask;

    if (firstByteBitsLeft > bitsCount)
    {
        bitOffset.* += bitsCount;
        return firstByteBits;
    }

    s.* = s.sliceFrom(s.getPosition(1));

    const bitsLeftToRead = bitsCount - firstByteBitsLeft;
    bitOffset.* = bitsLeftToRead;

    if (bitsLeftToRead == 0)
    {
        return firstByteBits;
    }

    const secondByte = s.peekFirstByte().?;
    const secondByteBits = secondByte >> (8 - bitsLeftToRead);
    const result = firstByteBits | (secondByteBits << firstByteBitsLeft);
    return result;
}

const BackReference = struct
{
    unadjustedDistance: u16,
    unadjustedLength: u8,

    pub fn length(self: BackReference) u8
    {
        return self.unadjustedLength + 3;
    }
    pub fn distance(self: BackReference) u16
    {
        return self.unadjustedDistance + 1;
    }
};

const LengthCode = struct
{
};

const Symbol = union(enum)
{
    endBlock: bool,
    literalValue: u8,
    backReference: BackReference,
    lengthCode: LengthCode,
};

fn readSymbol(context: *DeflateContext) !Symbol
{
    // TODO: This is broken, it needs to store all intermediate values on the state!
    const code = try readNBits(context, 7);
    if (code == 0)
    {
        // ?
        return .{ .endBock = true };
    }

    const lengthCodeUpperLimit = 0b001_0111;
    if (code <= lengthCodeUpperLimit)
    {
        const length = code + lengthCodeUpperLimit;
        const distanceBitCount = d: {
            switch (length)
            {
                0 ... 3 => break :d 0,
                else => break :d (length - 2) / 2,
            }
        };
        const baseDistance = d: {
            switch (length)
            {
                0 ... 3 => break :d length,
                4 ... 5 =>
                {
                },
            }
        };


    }


}

pub fn deflate(context: *DeflateContext) !void
{
    const state = context.state;
    switch (state.key)
    {
        .IsFinal =>
        {
            const isFinal = try readNBits(context, 1);
            state.isFinal = isFinal;
            state.key = DeflateStateKey.BlockType;
        },
        .BlockType =>
        {
            const blockType = try readNBits(context, 2);
            state.blockType = @enumFromInt(blockType);

            switch (state.blockType)
            {
                .NoCompression =>
                {
                    if (state.bitOffset != 0)
                    {
                        _ = pipelines.removeFirst(context.sequence) catch unreachable;
                        state.bitOffset = 0;
                    }
                    state.key = DeflateStateKey.NoCompressionLen;
                }
            }
        },
        .NoCompressionLen =>
        {
            const len = try pipelines.readNetworkUnsigned(context.sequence, u16);
            state.key = DeflateStateKey.NoCompressionNLen;
            state.len = len;
        },
        .NoCompressionNLen =>
        {
            const nlen = try pipelines.readNetworkUnsigned(context.sequence, u16);
            if (nlen != ~state.len)
            {
                return error.NLenNotOnesComplement;
            }
            state.key = .UncompressedBytes;
            state.dataBytesRead = 0;
        },
        .UncompressedBytes =>
        {
            // TODO:
            // use the read bytes helper, move it from the parser
            // into pipelines or pipelines.extensions
        },
    }
}
