const helper = @import("helper.zig");
const std = helper.std;
const huffman = helper.huffman;
const pipelines = helper.pipelines;

pub const noCompression = @import("noCompression.zig");
pub const fixed = @import("fixed.zig");
pub const dynamic = @import("dynamic.zig");

const BlockType = enum(u2)
{
    NoCompression = 0,
    FixedHuffman = 1,
    DynamicHuffman = 2,
    Reserved = 3,
};

pub const Context = struct
{
    state: *State,
    common: *const helper.CommonContext,

    pub fn sequence(self: *const Context) *pipelines.Sequence
    {
        return self.common.sequence;
    }
    pub fn allocator(self: *const Context) std.mem.Allocator
    {
        return self.common.allocator;
    }
    pub fn output(self: *const Context) *helper.OutputBuffer
    {
        return self.common.output;
    }
};

pub const State = struct
{
    action: Action = .IsFinal,
    bitOffset: u3 = 0,

    isFinal: bool = false,
    len: u16 = 0,

    dataBytesRead: u16 = 0,
    lastSymbol: ?helper.Symbol = null,

    blockState: union(BlockType)
    {
        NoCompression: noCompression.State,
        FixedHuffman: fixed.SymbolDecompressionState,
        DynamicHuffman: dynamic.State,
        Reserved: void,
    } = .{ .Reserved = {} },
};

pub const Action = enum
{
    IsFinal,
    BlockType,
    BlockInit,
    DecompressionLoop,
    Done,

    pub const Initial: Action = .IsFinal;
};

// Returns true when it's done with a block.
pub fn deflate(context: *const Context) !bool
{
    const state = context.state;
    switch (state.action)
    {
        .IsFinal =>
        {
            const isFinal = try helper.readBits(context, u1);
            state.isFinal = isFinal == 1;
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
                        _ = pipelines.removeFirst(context.sequence()) catch unreachable;
                        state.bitOffset = 0;
                    }
                    // It still needs to read some metadata though.
                    state.blockState = .{
                        .NoCompression = .{
                            .init = std.mem.zeroes(noCompression.InitState),
                        },
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
                    state.action = .BlockInit;
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
                    const done = try noCompression.initState(context, &s.init);
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
                        try dynamic.initializeDecompressionState(s, context.allocator());
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
                    try noCompression.decompress(context, &s.decompression);
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
                    const symbol = try dynamic.decompressSymbol(context, &s.decompression);
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

test
{
    _ = huffman;
}
