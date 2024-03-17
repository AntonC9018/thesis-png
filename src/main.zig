const std = @import("std");
const pipelines = @import("pipelines.zig");
const parser = @import("parser/parser.zig");
const zlib = @import("zlib/zlib.zig");
const deflate = @import("zlib/deflate.zig");

const raylib = @import("raylib");

const resourcesDir = "raylib/raylib/examples/text/resources/";

// 1. Transform parser results into tree
// 2. Draw bytes on screen
// 3. Draw image
// 4. Visualize the tree
// 5. Allow switching pages changing the current range
// 6. Deleting invisible parts of the tree
//

const ChildrenList = struct
{
    array: std.ArrayListUnmanaged(usize) = .{},

    pub fn len(self: *const ChildrenList) usize
    {
        return self.array.items.len;
    }
};

pub const ChunkDataNodeType = parser.ChunkType;

const chunks = parser.chunks;

const NodeIndex = usize;
const NodeDataIndex = usize;

const NodeType = union(enum)
{
    TopLevel: parser.Action,
    Chunk: parser.ChunkAction,

    ChunkData: union(enum)
    {
        RGB: chunks.RGBAction,
        ImageHeader: chunks.ImageHeaderAction,
        PrimaryChrom: chunks.PrimaryChromState,
        ICCProfile: chunks.ICCProfileAction,
        TextAction: chunks.TextAction,
        CompressedText: chunks.CompressedTextAction,
    },

    Zlib: zlib.Action,
    Deflate: deflate.Action,
    NoCompression: deflate.noCompression.InitStateAction,
    FixedHuffman: deflate.fixed.SymbolDecompressionAction,
    DynamicHuffman: union(enum)
    {
        Decompression: deflate.dynamic.DecompressionAction,
        CodeDecoding: deflate.dynamic.CodeDecodingAction,
        CodeFrequency: deflate.dynamic.CodeFrequencyAction,
    },

    // Data from some nodes is skipped.
    Skipped: void,

    pub fn format(
        self: NodeType,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype) !void
    {
        switch (self)
        {
            inline else => |v| try writer.print("{}", .{ v }),
        }
    }
};

const NodeData = struct
{
    // Maybe add a reference count here to be able to know when to delete things.
    type: NodeType,
    value: union(enum)
    {
        String: []const u8,
        Number: usize,
        ChunkType: parser.ChunkType,
        None: void,
    },
};

const bitsInByte = 8;

const NodePositionOffset = struct
{
    byte: isize = 0,
    bit: isize = 0,

    pub fn addBits(self: NodePositionOffset, bits: isize) NodePositionOffset
    {
        return .{
            .byte = self.byte,
            .bit = self.bit + bits,
        };
    }

    pub fn negate(self: NodePositionOffset) NodePositionOffset
    {
        return .{
            .byte = -self.byte,
            .bit = -self.bit,
        };
    }

    pub fn add(a: NodePositionOffset, b: NodePositionOffset) NodePositionOffset
    {
        return .{
            .byte = a.byte + b.byte,
            .bit = a.bit + b.bit,
        };
    }

    pub fn normalized(self: NodePositionOffset) NodePositionOffset
    {
        return .{
            .byte = self.byte + @divFloor(self.bit, bitsInByte),
            .bit = @mod(self.bit, bitsInByte),
        };
    }

    pub fn isLessThanOrEqualToZero(self: NodePositionOffset) bool
    {
        const n = self.normalized();
        return n.byte <= 0 and n.byte == 0;
    }
};


test "Normalization"
{
    const doNodeOffsetNormalizationTest = struct
    {
        fn f(
            before: NodePositionOffset,
            after: NodePositionOffset) !void
        {
            const norm = before.normalized();
            try std.testing.expectEqualDeep(after, norm);
        }
    }.f;

    try doNodeOffsetNormalizationTest(
        .{ .byte = 0, .bit = -17, },
        .{ .byte = -3, .bit = 7, });

    try doNodeOffsetNormalizationTest(
        .{ .byte = 0, .bit = 17, },
        .{ .byte = 2, .bit = 1, });
}

const NodePosition = struct
{
    byte: usize,
    bit: u3,

    pub fn compareTo(a: NodePosition, b: NodePosition) isize
    {
        const byteDiff = @as(isize, @intCast(a.byte)) - @as(isize, @intCast(b.byte));
        if (byteDiff != 0)
        {
            return byteDiff;
        }

        const bitDiff = @as(isize, @intCast(a.bit)) - @as(isize, @intCast(b.bit));
        return bitDiff;
    }

    fn asOffset(self: NodePosition) NodePositionOffset
    {
        return .{
            .byte = @intCast(self.byte),
            .bit = @intCast(self.bit),
        };
    }

    pub fn offsetTo(a: NodePosition, b: NodePosition) NodePositionOffset
    {
        const fromNegative = a.asOffset().negate();
        const to = b.asOffset();
        const result = fromNegative.add(to);
        return result;
    }

    fn fromOffset(offset: NodePositionOffset) NodePosition
    {
        return .{
            .byte = @intCast(offset.byte),
            .bit = @intCast(offset.bit),
        };
    }

    pub fn add(self: NodePosition, added: NodePositionOffset) NodePosition
    {
        const resultOffset = self.asOffset().add(added).normalized();
        std.debug.assert(resultOffset.byte >= 0);
        const result = fromOffset(resultOffset);
        return result;
    }
};

const NodeSpan = struct
{
    start: NodePosition,
    endInclusive: NodePosition,

    pub fn bitLen(span: *const NodeSpan) usize
    {
        const difference = span.start.offsetTo(span.endInclusive);
        const bitsDiff = difference.byte * bitsInByte + difference.bit + 1;
        return bitsDiff;
    }

    pub fn fromStartAndEndExclusive(startPos: NodePosition, endPosExclusive: NodePosition) NodeSpan
    {
        const comparison = endPosExclusive.compareTo(startPos);
        std.debug.assert(comparison > 0);
        const endInclusive_ = endPosExclusive.add(.{ .bit = -1 });
        return .{
            .start = startPos,
            .endInclusive = endInclusive_,
        };
    }

    pub fn fromStartAndLen(startPos: NodePosition, len: NodePositionOffset) NodeSpan
    {
        const endOffset = len.addBits(-1);
        std.debug.assert(!endOffset.isLessThanOrEqualToZero());

        return .{
            .start = startPos,
            .endInclusive = startPos.add(endOffset),
        };
    }
};

const Node = struct
{
    // In case there are child nodes, includes the position of the start
    // of the first child node, and the end position of the last child node.
    // The idea is that there may be gaps in the range of the span,
    // but it does allow you to gauge the edges.
    // If there are no children, it's just the range of the node.
    span: NodeSpan,
    nodeData: ?NodeDataIndex,
    children: ChildrenList,
};

const AST = struct
{
    rootNodes: std.ArrayList(NodeIndex),
    nodes: std.ArrayList(Node),
    nodeData: std.ArrayList(NodeData),

    pub fn childrenAllocator(self: *AST) std.mem.Allocator
    {
        return self.nodes.allocator;
    }
};

pub fn createTestTree(allocator: std.mem.Allocator) !AST
{
    var tree: AST = .{
        .rootNodes = std.ArrayList(usize).init(allocator),
        .nodes = std.ArrayList(Node).init(allocator),
        .nodeData = std.ArrayList(NodeData).init(allocator),
    };
    const data = try tree.nodeData.addManyAsArray(10);
    const defaultType = NodeType { .TopLevel = .Chunk };
    data.*[0] = .{
        .type = defaultType,
        .value = .{
            .string = "Test",
        },
    };
    data.*[1] = .{
        .type = defaultType,
        .value = .{
            .string = "Hello world, this is a longer piece of text",
        },
    };
    for (2 .. data.len) |i|
    {
        data.*[i] = .{
            .type = defaultType,
            .value = .{
                .number = i,
            },
        };
    }

    var position = NodePosition
    {
        .byte = 0,
        .bit = 0,
    };

    {
        const endPosition = position.add(.{ .byte = 1 });
        const node = Node
        {
            .span = NodeSpan.fromStartAndEndExclusive(position, endPosition),
            .nodeData = null,
            .children = .{},
        };
        try tree.nodes.append(node);
        position = endPosition;
    }
    // Make a couple nodes to serve as children.
    const childrenCount = 3;
    const parentNode = try tree.nodes.addOne();

    var children: ChildrenList = .{};
    try children.array.ensureTotalCapacity(tree.childrenAllocator(), childrenCount);

    for (0 .. childrenCount) |i|
    {
        const endPosition = position.add(.{
            .byte = @intCast(i + 1),
            .bit = @intCast(i * 6),
        });
        // std.debug.print("From: {d},{d}\n", .{ position.byte, position.bit });
        // std.debug.print("To: {d},{d}\n", .{ endPosition.byte, endPosition.bit });
        const node = Node
        {
            .span = NodeSpan.fromStartAndEndExclusive(position, endPosition),
            .nodeData = i,
            .children = .{},
        };
        const currentIndex = tree.nodes.items.len;
        try children.array.append(tree.childrenAllocator(), currentIndex);
        try tree.nodes.append(node);
        position = endPosition;
    }

    {
        const childIndices = children.array.items;
        const firstChild = childIndices[0];
        const lastChild = childIndices[childIndices.len - 1];

        const start = tree.nodes.items[firstChild].span.start;
        const end = tree.nodes.items[lastChild].span.endInclusive;
        parentNode.* = Node
        {
            .span = .{
                .start = start,
                .endInclusive = end,
            },
            .nodeData = null,
            .children = children,
        };
    }

    (try tree.rootNodes.addManyAsArray(2)).* = .{ 0, 1 };
    return tree;
}

const debug = @import("pngDebug.zig");

pub fn getBitPosition(state: *const parser.State) u3
{
    const getBitPositionFromZlib = struct
    {
        fn f(z: *const zlib.State) u3
        {
            return switch (z.action)
            {
                else => 0,
                .CompressedData => z.decompressor.deflate.bitOffset,
            };
        }
    }.f;

    switch (state.action.key)
    {
        else => return 0,
        .Chunk =>
        {
            const chunk = &state.chunk;
            switch (chunk.action.key)
            {
                else => return 0,
                .Data =>
                {
                    const data = &chunk.dataState;
                    if (!data.action.initializedPointer().*)
                    {
                        return 0;
                    }
                    switch (chunks.getActiveChunkDataState(chunk))
                    {
                        else => return 0,
                        .CompressedText => |compressedText|
                        {
                            return getBitPositionFromZlib(&compressedText.zlib);
                        },
                        .ImageData =>
                        {
                            // TODO:
                            // Check if the carry over buffer has any bytes,
                            // then the start will be in there.
                            return getBitPositionFromZlib(&state.imageData.zlib);
                        },
                        .ICCProfile => |iccProfile|
                        {
                            return getBitPositionFromZlib(iccProfile.zlib);
                        },
                        .InternationalText =>
                        {
                            // TODO: Unimplemented
                            unreachable;
                        }
                    }
                },
            }
        },
    }
}

fn getCompletePosition(
    state: *const parser.State,
    sequence: *const pipelines.Sequence) NodePosition
{
    const byteOffset = sequence.getStartBytePosition();
    const bitOffset = getBitPosition(state, sequence);
    return .{
        .byte = byteOffset,
        .bit = bitOffset,
    };
}

const NodeResult = struct 
{
    item: *Node,
    index: NodeIndex,
};

const NodeDataResult = struct
{
    item: *NodeData,
    index: NodeDataIndex,
};

const TreeConstructionContext = struct
{
    parserState: parser.State,
    allocator: std.mem.Allocator,
    nodePath: std.ArrayListUnmanaged(NodeIndex),
    tree: AST,
    
    pub fn lastNode(self: *const TreeConstructionContext) ?NodeResult
    {
        const nodes = self.nodePath.items;
        if (nodes.len == 0)
        {
            return null;
        }
        const index = nodes.len - 1;
        return .{
            .item = &nodes[index],
            .index = index,
        };
    }

    pub fn addUninitializedNodeAtPosition(
        self: *TreeConstructionContext,
        params: struct
        {
            startPosition: NodePosition,
            parentNode: ?*Node,
            data: ?NodeDataIndex = null,
        }) !NodeResult
    {
        const nodes = &self.tree.nodes;
        const index = nodes.items.len;
        try nodes.addOne(std.mem.zeroInit(Node, .{
            .span = std.mem.zeroInit(NodeSpan, .{
                .start = params.startPosition,
            }),
        }));

        if (params.parentNode) |parent|
        {
            // NOTE: the span has not yet been updated at this point.
            try parent.children.array.addOne(self.tree.childrenAllocator(), index);
        }
        else
        {
            try self.tree.rootNodes.addOne(index);
        }

        return .{ 
            .item = &nodes.items[index],
            .index = index,
        };
    }

    pub fn addNodeData(
        self: *TreeConstructionContext,
        params: struct
        {
            type: NodeType,
        }) !NodeDataResult
    {
        const nodeDatas = &self.tree.nodeData;
        const index = nodeDatas.items.len;
        try nodeDatas.addOne(NodeData
        {
            .type = params.type,
            .value = .{ .none = {} },
        });

        return .{
            .item = &nodeDatas.items[index],
            .index = index,
        };
    }
};

const AddChildToLastNodeResult = struct
{
    node: NodeResult,
    data: NodeDataResult,
};

fn addChildToLastNode(
    context: *TreeConstructionContext,
    params: struct
    {
        position: NodePosition,
        nodeType: NodeType,
    })
    !AddChildToLastNodeResult
{
    const data = try context.addNodeData(.{
        .type = params.nodeType,
    });
    const lastNode = context.lastNode();
    const node = try context.addUninitializedNodeAtPosition(.{
        .startPosition = params.position,
        .parentNode = if (lastNode) |n| n.index else null,
        .dataNode = data.index,
    });
    return .{
        .node = node,
        .data = data,
    };
}

fn getNodeType(action: anytype) NodeType
{
    if (@TypeOf(action) == void)
    {
        return .{
            .Skipped = void,
        };
    }

    const nodeTypeInfo = @typeInfo(NodeType);
    for (nodeTypeInfo.Union.fields) |field|
    {
        const fieldTypeInfo = @typeInfo(field.type);
        switch (fieldTypeInfo)
        {
            .Union => |u|
            {
                for (u.fields) |nestedField|
                {
                    if (@TypeOf(action) == nestedField.type)
                    {
                        return @unionInit(NodeType, field.name, 
                            @unionInit(field.type, nestedField.name, action));
                    }
                }
            },
            .Struct, .Enum =>
            {
                if (@TypeOf(action) == field.type)
                {
                    return @unionInit(NodeType, field.name, action);
                }
            },
            else => unreachable,
        }
    }

    @compileError("Unhandled action type: " ++ @typeName(@TypeOf(action)));
}

fn maybeAddChildToLastNode(
    context: *TreeConstructionContext,
    action: anytype, // Initiable(Action)
    position: NodePosition)
    !?AddChildToLastNodeResult
{
    if (action.initialized)
    {
        return null;
    }
    const nodeType = getNodeType(action.keyPointer().*);
    const result = try addChildToLastNode(context, .{
        .position = position,
        .nodeType = nodeType,
    });
    return result;
}

fn initNodesForCurrentAction(
    context: *TreeConstructionContext,
    sequence: *const pipelines.Sequence) !void
{
    const currentPosition = getCompletePosition(context.parserState, sequence);
    const state = &context.parserState;
    
    if (try maybeAddChildToLastNode(context, state.action, currentPosition))
    {
        return;
    }

    switch (state.action.key)
    {
        .Signature => {},
        .Chunk =>
        {
            const chunk = &state.chunk;
            // The ways to figure out if the node has already been created:
            // 1. Scan. Unreliable.
            // 2. Check the length. Create if doesn't exist. Will work, but it's fragile.
            // 3. Do the initialized field for every action. 
            //    Reliable, easy to manage, but forces structure on the parser.
            // 
            // I think 3 is best.
            if (try maybeAddChildToLastNode(context, chunk.action, currentPosition)) |n|
            {
                if (chunk.action.key == .Data)
                {
                    n.data.item.value = .{
                        .ChunkType = chunk.object.type,
                    };
                }
                return;
            }

            switch (chunk.action.key)
            {
                else => return,
                .Data =>
                {
                    const actionAndState = chunks.getActiveChunkDataActionAndState(chunk);
                    switch (actionAndState)
                    {
                        inline else => |*t|
                        {
                            try maybeAddChildToLastNode(context, t.action, currentPosition);
                            return;
                        }
                    }
                },
            }
        },
    }
}

fn parseIntoTree(allocator: std.mem.Allocator) !AST
{
    // Special case: filling in the data node of a previously created node for image data spread across chunks.
    // Take bit offset into consideration.
    var testContext = try debug.openTestReader(allocator);
    defer testContext.deinit();

    const reader = &testContext.reader;
    var parserState = parser.createParserState();
    const parserSettings = parser.Settings
    {
        .logChunkStart = true,
    };


    outerLoop: while (true)
    {
        const readResult = reader.read() catch unreachable;
        const startPos = getCompletePosition(readResult.sequence);
    }
}

pub fn main() !void
{
    const allocator = std.heap.page_allocator;
    const tree = try createTestTree(allocator);

    // try .readTestFile();

    raylib.SetConfigFlags(raylib.ConfigFlags{ .FLAG_WINDOW_RESIZABLE = true });
    raylib.InitWindow(800, 800, "hello world!");
    raylib.SetTargetFPS(60);

    defer raylib.CloseWindow();

    while (!raylib.WindowShouldClose())
    {
        raylib.BeginDrawing();
        defer raylib.EndDrawing();
        
        raylib.ClearBackground(raylib.BLACK);
        raylib.DrawFPS(10, 10);

        const fontSize = 20;
        const lineHeight = 30;
        const Context = struct
        {
            currentPosition: raylib.Vector2i,
            tree: AST,
            allocator: std.mem.Allocator,

            fn drawTextLine(context: *@This(), s: [:0]const u8) void
            {
                const p = &context.currentPosition;
                raylib.DrawText(s, p.x, p.y, fontSize, raylib.WHITE);
                p.y += lineHeight;
            }
        };
        var context = Context
        {
            .currentPosition = .{ .x = 10, .y = 30 + 10 },
            .tree = tree,
            .allocator = allocator,
        };

        const draw = struct
        {
            fn f(nodeIndex: usize, context_: *Context) !void
            {
                const node: Node = context_.tree.nodes.items[nodeIndex];

                var writerBuf = std.ArrayList(u8).init(context_.allocator);
                defer writerBuf.clearAndFree();
                const writer = writerBuf.writer();

                {
                    const start = node.span.start;
                    const end = node.span.endInclusive;
                    try writer.print(
                        "Node {d}, Range [{d},{d}:{d},{d}]",
                        .{
                            nodeIndex,
                            start.byte,
                            start.bit,
                            end.byte,
                            end.bit,
                        });
                }

                if (node.nodeData) |dataIndex|
                {
                    const data = context_.tree.nodeData.items[dataIndex];

                    try writer.print(", Type: {}, ", .{ data.type });
                    _ = try writer.write("Value: ");
                    try switch (data.value)
                    {
                        .string => |s| writer.print("{s}", .{ s }),
                        .number => |n| writer.print("{d}", .{ n }),
                    };
                }
                try writer.writeByte(0);

                context_.drawTextLine(writerBuf.items[0 .. writerBuf.items.len - 1: 0]);

                if (node.children.len() > 0)
                {
                    const offsetSize = 20;
                    context_.currentPosition.x += offsetSize;
                    defer context_.currentPosition.x -= offsetSize;

                    for (node.children.array.items) |childNodeIndex|
                    {
                        try f(childNodeIndex, context_);
                    }
                }
           }
        }.f;

        for (tree.rootNodes.items) |rootNodeIndex|
        {
            try draw(rootNodeIndex, &context);
        }
    }
}

test
{ 
    _ = pipelines;
    _ = @import("zlib/zlib.zig");
}

