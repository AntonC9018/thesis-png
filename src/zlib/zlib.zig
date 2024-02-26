const helper = @import("helper.zig");
const std = helper.std;
const huffman = helper.huffman;
const pipelines = helper.pipelines;
const noCompression = @import("noCompression.zig");

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
    lastSymbol: ?helper.Symbol,

    blockState: union(BlockType)
    {
        NoCompression: noCompression.State,
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
    Done,
};

// Returns true when it's done with a block.
pub fn deflate(context: *DeflateContext) !bool
{
    const state = context.state;
    switch (state.action)
    {
        .IsFinal =>
        {
            const isFinal = try helper.readBits(context, u1);
            state.isFinal = isFinal;
            state.action = .BlockType;
        },
        .BlockType =>
        {
            const blockType = try helper.readBits(context, u2);
            const typedBlockType: BlockType = @enumFromInt(blockType);

            switch (typedBlockType)
            {
                .NoCompression =>
                {
                    // The uncompressed info starts on a byte boundary.
                    if (state.bitOffset != 0)
                    {
                        _ = pipelines.removeFirst(context.sequence) catch unreachable;
                        state.bitOffset = 0;
                    }
                    // It still needs to read some metadata though.
                    state.blockState = .{
                        .NoCompression = std.mem.zeroes(noCompression.State),
                    };
                    state.action = .BlockInit;
                },
                .FixedHuffman =>
                {
                    state.blockState = .{
                        .FixedHuffman = fixed.SymbolDecompressionState.Initial,
                    };
                    // It doesn't need to read any metadata.
                    // The symbol tables are predefined by the spec.
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
                    // It's getting initialized in mutliple calls to this.
                    // You have to call the whole function again.
                    // (Could have done a for loop within here, but it's more flexible otherwise).
                    const done = try noCompression.initState(context, s.init);
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
        .DecompressionLoop =>
        {
            switch (state.blockState)
            {
                .NoCompression => |*s|
                {
                    // This reads as much as possible, because there's nothing interesting going on.
                    try noCompression.decompress(context, s.decompression);
                    state.action = .Done;
                },
                .FixedHuffman => |*s|
                {
                    const symbol = try fixed.decompressSymbol(context, s);
                    state.lastSymbol = symbol;
                    const done = try helper.writeSymbolToOutput(context, symbol);
                    return done;
                },
                .DynamicHuffman => |*s|
                {
                    const symbol = try dynamic.decompressSymbol(context, s.decompression);
                    state.lastSymbol = symbol;
                    const done = try helper.writeSymbolToOutput(context, symbol);
                    return done;
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

