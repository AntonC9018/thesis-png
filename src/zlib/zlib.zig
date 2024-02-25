const helper = @import("helper.zig");
const std = helper.std;
const huffman = helper.huffman;
const pipelines = helper.pipelines;

const fixed = @import("fixed.zig");
const dynamic = @import("dynamic.zig");

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
    allocator: std.mem.Allocator,
    output: *helper.OutputBuffer,
};

const DeflateState = struct
{
    action: DeflateStateAction,
    bitOffset: u4,

    isFinal: bool,
    len: u16,

    dataBytesRead: u16,

    blockState: union(BlockType)
    {
        NoCompression: NoCompressionState,
        FixedHuffman: fixed.SymbolDecompressionState,
        DynamicHuffman: dynamic.State,
        Reserved: void,
    },
};

const DeflateStateAction = enum
{
    IsFinal,
    BlockType,

    BlockInit,

    DecompressionLoop,
};

pub fn deflate(context: *DeflateContext) !bool
{
    const state = context.state;
    switch (state.action)
    {
        .IsFinal =>
        {
            const isFinal = try helper.readBits(context, u1);
            state.isFinal = isFinal;
            state.action = DeflateStateAction.BlockType;
        },
        .BlockType =>
        {
            const blockType = try helper.readBits(context, u2);
            const typedBlockType: BlockType = @enumFromInt(blockType);

            switch (typedBlockType)
            {
                .NoCompression =>
                {
                    if (state.bitOffset != 0)
                    {
                        _ = pipelines.removeFirst(context.sequence) catch unreachable;
                        state.bitOffset = 0;
                    }
                    state.blockState = .{
                        .NoCompression = std.mem.zeroes(NoCompressionState),
                    };
                    state.action = .BlockInit;
                },
                .FixedHuffman =>
                {
                    state.blockState = .{
                        .FixedHuffman = fixed.SymbolDecompressionState.Initial,
                    };
                    state.action = .DecompressionLoop;
                },
                .DynamicHuffman =>
                {
                    state.blockState = .{
                        .DynamicHuffman = .{
                            .codeDecoding = std.mem.zeroes(dynamic.CodeDecodingState),
                        },
                    };
                    state.action = .DynamicHuffmanHeader;
                },
                .Reserved =>
                {
                    state.blockState = .{
                        .Reserved = {},
                    };
                    return error.ReservedBlockTypeUsed;
                },
            }
        },
        .BlockInit =>
        {
            switch (state.blockState)
            {
                .NoCompression => |*s|
                {
                    const done = try initNoCompression(context, s.init);
                    if (done)
                    {
                        s.* = .{
                            .decompression = .{
                                .bytesLeftToCopy = s.init.len,
                            },
                        };
                        state.action = .DecompressionLoop;
                    }
                },
                .FixedHuffman => unreachable,
                .DynamicHuffman => |*s|
                {
                    const done = try dynamic.decodeCodes(context, &s.codeDecoding);
                    if (done)
                    {
                        dynamic.initializeDecompressionState(s, context.allocator);
                        state.action = .DecompressionLoop;
                    }
                },
                .Reserved => unreachable,
            }
        },
        .DecompressionLoop => decompression:
        {
            switch (state.blockState)
            {
                .NoCompression => |*s|
                {
                    if (s.decompression.bytesLeftToCopy == 0)
                    {
                        state.action = .Done;
                        break :decompression;
                    }

                    const sequence = context.sequence;
                    var iter = pipelines.SegmentIterator.create(sequence)
                        orelse return error.NotEnoughBytes;
                    while (true)
                    {
                        const segment = iter.current();
                        const len = segment.len;
                        const bytesWillRead = @min(s.decompression.bytesLeftToCopy, len);

                        const slice = segment[0 .. bytesWillRead];
                        context.output.writeBytes(slice)
                            catch |err|
                            {
                                sequence.* = sequence.sliceFrom(iter.currentPosition);
                                return err;
                            };

                        s.decompression.bytesLeftToCopy -= bytesWillRead;
                        if (s.decompression.bytesLeftToCopy == 0)
                        {
                            const currentPos = iter.currentPosition.add(bytesWillRead);
                            sequence.* = sequence.sliceFrom(currentPos);
                            break;
                        }

                        const advanced = iter.advance();
                        if (!advanced)
                        {
                            sequence.* = sequence.sliceFrom(iter.currentPosition);
                            return error.NotEnoughBytes;
                        }
                    }

                    state.action = .Done;
                },
                .FixedHuffman =>
                {
                },
                .DynamicHuffman => |*s|
                {
                    while (true)
                    {
                        const done = try dynamic.decompress(context, s.decompression);
                        if (done)
                        {
                            state.action = .Done;
                            break;
                        }
                    }
                },
                .Reserved => unreachable,
            }
        },
        .Done => unreachable,
    }
    return state.action == .Done;
}

fn copyConst(from: type, to: type) type
{
    return @Type(t: {
        var info = @typeInfo(to).Pointer;
        info.is_const = @typeInfo(from).Pointer.is_const;
        break :t info;
    });
}

test
{
    _ = huffman;
}

const NoCompressionInitStateAction = enum
{
    Len,
    NLen,
    Done,
};

const NoCompressionState = union
{
    init: struct
    {
        action: NoCompressionInitStateAction,
        len: u16,
        nlen: u16,
    },
    decompression: struct
    {
        bytesLeftToCopy: u16,
    },
};

pub fn initNoCompression(context: *DeflateContext, state: *NoCompressionState) !bool
{
    switch (state.action)
    {
        .Len =>
        {
            const len = try pipelines.readNetworkUnsigned(context.sequence, u16);
            state.len = len;
            state.action = .NLen;
            return false;
        },
        .NLen =>
        {
            const nlen = try pipelines.readNetworkUnsigned(context.sequence, u16);
            state.nlen = nlen;

            if (nlen != ~state.len)
            {
                return error.NLenNotOnesComplement;
            }

            state.action = .Done;
            return true;
        },
        .Done => unreachable,
    }
}
