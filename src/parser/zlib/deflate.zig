const helper = @import("helper.zig");
const std = helper.std;
const huffman = helper.huffman;
const pipelines = helper.pipelines;

pub const OutputBuffer = helper.OutputBuffer;
pub const noCompression = @import("noCompression.zig");
pub const fixed = @import("fixed.zig");
pub const dynamic = @import("dynamic.zig");
pub const Symbol = helper.Symbol;

pub const BlockType = enum(u2)
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

    pub fn level(self: *Context) helper.LevelContext(Context)
    {
        return .{
            .context = self,
            .data = self.common.level(),
        };
    }
    pub fn sequence(self: *Context) *pipelines.Sequence
    {
        return self.common.sequence();
    }
    pub fn allocator(self: *Context) std.mem.Allocator
    {
        return self.common.allocator();
    }
    pub fn output(self: *Context) *helper.OutputBuffer
    {
        return self.common.output;
    }
    pub fn getCurrentNodePosition(self: *Context) helper.NodePosition
    {
        return .{
           .byte = self.sequence().getStartBytePosition(),
           .bit = self.state.bitOffset,
        };
    }
};

pub const State = struct
{
    action: Action = Action.Initial,
    bitOffset: u3 = 0,

    isFinal: bool = false,
    len: u16 = 0,

    dataBytesRead: u16 = 0,

    symbolDecompressionInitialized: bool,

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

    pub const Initial: Action = .IsFinal;
};

// Returns true when it's done with a block.
pub fn deflate(context: *Context) !bool
{
    const state = context.state;

    try context.level().pushNode(.{
        .Deflate = state.action,
    });
    defer context.level().pop();

    switch (state.action)
    {
        .IsFinal =>
        {
            const value = try helper.readBits(.{ .context = context }, u1);
            const isFinal = value == 1;
            state.isFinal = isFinal;
            try context.level().completeNodeWithValue(.{
                .Bool = isFinal,
            });
            state.action = .BlockType;
        },
        .BlockType =>
        {
            const blockType = try helper.readBits(.{ .context = context }, u2);
            const typedBlockType: BlockType = @enumFromInt(blockType);

            std.debug.print("Block type value: {}\n", .{typedBlockType});
            try context.level().completeNodeWithValue(.{
                .BlockType = typedBlockType,
            });

            switch (typedBlockType)
            {
                .NoCompression =>
                {
                    // The uncompressed info starts on a byte boundary.
                    skipToWholeByte(context);

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
                    // skipToWholeByte(context);

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
                        try context.level().completeNode();
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
                        try dynamic.initializeDecompressionState(s, context.allocator()());
                        try context.level().completeNode();
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
                    return true;
                },
                .Reserved => unreachable,
                inline else => |*s, mechanism|
                {
                    const symbol = symbol:
                    {
                        try context.level().pushNode(.ZlibSymbol);
                        defer context.level().pop();

                        const symbol_ = switch (mechanism)
                        {
                            .DynamicHuffman => try dynamic.decompressSymbol(context, &s.decompression),
                            .FixedHuffman => try fixed.decompressSymbol(context, s.key),
                        };

                        try context.level().completeNodeWithValue(.{
                            .ZlibSymbol = symbol_,
                        });
                        break :symbol symbol_;
                    };
                    const done = try helper.writeSymbolToOutput(context, symbol);
                    return done;
                },
            }
        },
    }
    return false;
}

pub fn skipToWholeByte(context: *Context) void
{
    const state = context.state;
    if (state.bitOffset != 0)
    {
        _ = pipelines.removeFirst(context.sequence()) catch unreachable;
        state.bitOffset = 0;
    }
}

test
{
    _ = huffman;
}
