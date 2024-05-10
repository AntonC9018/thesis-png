const helper = @import("helper.zig");
const std = helper.std;
const huffman = helper.huffman;
const pipelines = helper.pipelines;
const parser = helper.parser;

pub const OutputBuffer = helper.OutputBuffer;
pub const noCompression = @import("noCompression.zig");
pub const fixed = @import("fixed.zig");
pub const dynamic = @import("dynamic.zig");
pub const Symbol = helper.Symbol;
pub const DecompressionValueType = helper.DecompressionValueType;

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
    common: *helper.CommonContext,

    pub fn level(self: *Context) helper.LevelContext(Context)
    {
        return .{
            .context = self,
            .data = self.common.levelData(),
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
    pub fn getStartBytePosition(self: *Context) helper.NodePosition
    {
        return .{
           .byte = self.sequence().getStartBytePosition(),
           .bit = self.state.bitOffset,
        };
    }
    pub fn nodeContext(self: *Context) *parser.NodeContext
    {
        return self.common.nodeContext();
    }
    pub fn settings(self: *Context) *const helper.Settings
    {
        return self.common.settings();
    }
};

pub const State = struct
{
    action: Action = Action.Initial,
    bitOffset: u3 = 0,

    isFinal: bool = false,
    len: u16 = 0,

    dataBytesRead: u16 = 0,

    blockState: union(BlockType)
    {
        NoCompression: noCompression.State,
        FixedHuffman: fixed.SymbolDecompressionState,
        DynamicHuffman: dynamic.State,
        Reserved: void,
    } = .Reserved,
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
                        try dynamic.initializeDecompressionState(s, context.allocator());
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
                            .FixedHuffman => try fixed.decompressSymbol(context, s),
                            else => unreachable,
                        };

                        if (symbol_) |symbol__|
                        {
                            try context.level().completeNodeWithValue(.{
                                .ZlibSymbol = symbol__,
                            });
                        }

                        break :symbol symbol_;
                    };
                    const done = try helper.writeSymbolToOutput(context, symbol);
                    if (done)
                    {
                        try context.level().completeNode();
                    }
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

fn readAllTextAllocRelative(allocator: std.mem.Allocator, relativePath: []const u8) ![]u8
{
    const cwd = std.fs.cwd();
    const absolutePath = try cwd.realpathAlloc(allocator, relativePath);
    defer allocator.free(absolutePath);

    var file = try std.fs.openFileAbsolute(absolutePath, .{
        .mode = .read_only,
    });
    defer file.close();

    const maxBytes = 99999;
    const compressedBytes = try file.readToEndAlloc(allocator, maxBytes);
    return compressedBytes;
}

test "Romeo dynamic"
{
    const allocator = std.heap.page_allocator;

    const compressedBytes = try readAllTextAllocRelative(allocator, "test_data/romeo.txt.deflate");
    defer allocator.free(compressedBytes);

    const decompressedBytes = try readAllTextAllocRelative(allocator, "test_data/romeo.txt");
    defer allocator.free(decompressedBytes);


    const segment = helper.pipelines.Segment
    {
        .data = .{
            .bytePosition = 0,
            .capacity = compressedBytes.len,
            .items = compressedBytes,
        },
        .nextSegment = null,
    };
    var sequence = helper.pipelines.Sequence
    {
        .range = .{
            .len = segment.len(),
            .start = .{
                .offset = 0,
                .segment = &segment, 
            },
            .end = .{
                .offset = @intCast(compressedBytes.len),
                .segment = &segment,
            },
        },
    };

    const FakeNodeOperations = struct
    {
        const h = parser.NodeOperations;
        const Self = @This();

        dataId: parser.ast.NodeDataId = 1,
        nodeId: parser.ast.NodeId = 1,
        mappings: std.ArrayListUnmanaged(struct
            {
                nodeId: parser.ast.NodeId,
                dataId: parser.ast.NodeDataId,
                value: parser.ast.NodeData,
            }) = .{},
        allocator: std.mem.Allocator,

        pub fn createSyntaxNode(self: *Self, _: h.SyntaxNodeCreationParams) h.Error!parser.ast.NodeId
        {
            const result = self.nodeId;
            self.nodeId += 1;

            try self.mappings.append(self.allocator, .{
                .nodeId = result,
                .dataId = parser.ast.invalidNodeDataId,
                .value = undefined,
            });

            return result;
        }
        pub fn completeSyntaxNode(self: *Self, value: h.SyntaxNodeCompletionParams) h.Error!void
        {
            for (0 .., self.mappings.items) |i, *m|
            {
                if (m.nodeId == value.id)
                {
                    if (m.dataId != parser.ast.invalidNodeDataId)
                    {
                        std.debug.print("Value {}\n", .{ m.value });
                    }
                    // std.debug.print("Type {}, Value {?}\n", .{
                    //     value.nodeType,
                    //     if (m.dataId != parser.ast.invalidNodeDataId)
                    //         m.value
                    //     else
                    //         null
                    // });
                    _ = self.mappings.orderedRemove(i);
                    return;
                }
            }
        }
        pub fn linkSemanticParent(_: *Self, _: h.SyntaxNodeSemanticLinkParams) h.Error!void
        {
        }
        pub fn createNodeData(self: *Self, params: h.NodeDataCreationParams) h.Error!parser.ast.NodeDataId
        {
            if (params.associatedNode == parser.ast.invalidNodeId)
            {
                return 0;
            }

            for (self.mappings.items) |*m|
            {
                if (m.nodeId == params.associatedNode)
                {
                    const result = self.dataId;
                    m.dataId = result;
                    m.value = params.value;
                    self.dataId += 1;
                    return result;
                }
            }
            return 0;
        }
        pub fn setNodeDataValue(self: *Self, params: h.NodeDataParams) h.Error!void
        {
            for (self.mappings.items) |*m|
            {
                if (m.dataId == params.id)
                {
                    m.value = params.value;
                    return;
                }
            }
        }
    };
    var fakeAst = FakeNodeOperations
    {
        .allocator = allocator,
    };
    var nodeContext = parser.NodeContext
    {
        .allocator = allocator,
        .operations = parser.NodeOperations.create(&fakeAst),
    };

    const settings = parser.Settings
    {
        .logChunkStart = false,
    };

    var outputBuffer = std.ArrayListUnmanaged(u8){};
    var windowSize: usize = 32000;
    var outputBufferThing = helper.OutputBuffer
    {
        .allocator = allocator,
        .array = &outputBuffer,
        .windowSize = &windowSize,
    };

    var commonContext = helper.CommonContext
    {
        .common = .{
            .allocator = allocator,
            .level = .{},
            .nodeContext = &nodeContext,
            .settings = &settings,
            .sequence = &sequence,
        },
        .output = &outputBufferThing,
    };
    var state = State
    {
    };

    var deflateContext = Context
    {
        .common = &commonContext,
        .state = &state,
    };

    while (true)
    {
        const done = try deflate(&deflateContext);
        if (done and sequence.len() <= 1)
        {
            break;
        }
    }

    const testing = std.testing;

    try testing.expectEqualStrings(decompressedBytes, outputBuffer.items);
}

