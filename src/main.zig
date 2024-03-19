const std = @import("std");
const pipelines = @import("pipelines.zig");
const parser = @import("parser/parser.zig");
const zlib = @import("zlib/zlib.zig");
const deflate = @import("zlib/deflate.zig");
const levels = @import("shared/level.zig");
const LevelContext = levels.LevelContext;
const LevelStats = levels.LevelStats;

const chunks = parser.chunks;
const debug = @import("pngDebug.zig");
const ast = @import("ast.zig");

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

    switch (state.action)
    {
        else => return 0,
        .Chunk =>
        {
            const chunk = &state.chunk;
            switch (chunk.action)
            {
                else => return 0,
                .Data =>
                {
                    const data = &chunk.dataState;
                    if (!data.action.initializedPointer().*)
                    {
                        return 0;
                    }
                    const zlibState = switch (chunks.getActiveChunkDataState(chunk))
                    {
                        else => null,
                        .CompressedText => |compressedText| &compressedText.zlib,
                        .ImageData => &state.imageData.zlib,
                        .ICCProfile => |iccProfile| &iccProfile.zlib,
                        // TODO: Unimplemented.
                        .InternationalText => unreachable,
                    };
                    if (zlibState) |s|
                    {
                        return getBitPositionFromZlib(s);
                    }
                    return 0;
                },
            }
        },
    }
}

fn getCompletePosition(
    state: *const parser.State,
    sequence: *const pipelines.Sequence) ast.Position
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
    item: *ast.Node,
    index: ast.NodeIndex,
};

const NodeDataResult = struct
{
    item: *ast.Data,
    index: ast.DataIndex,
};

const TreeConstructionContext = struct
{
    parserState: parser.State,
    allocator: std.mem.Allocator,
    nodePath: std.ArrayListUnmanaged(ast.NodeIndex),
    tree: ast.AST,
    levelStats: LevelStats,
    
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
            startPosition: ast.Position,
            parentNode: ?*ast.Node,
            data: ?ast.DataIndex = null,
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
        try nodeDatas.addOne(ast.Data
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

const AddChildNodeResult = struct
{
    node: NodeResult,
    data: NodeDataResult,
};

fn addChildToLastNode(
    context: *TreeConstructionContext,
    params: struct
    {
        position: ast.Position,
        nodeType: ast.NodeType,
    })
    !AddChildNodeResult
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

fn getNodeType(action: anytype) ast.NodeType
{
    if (@TypeOf(action) == void)
    {
        return .{
            .Skipped = void,
        };
    }

    const nodeTypeInfo = @typeInfo(ast.NodeType);
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
                        return @unionInit(ast.NodeType, field.name, 
                            @unionInit(field.type, nestedField.name, action));
                    }
                }
            },
            .Struct, .Enum =>
            {
                if (@TypeOf(action) == field.type)
                {
                    return @unionInit(ast.NodeType, field.name, action);
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
    position: ast.Position)
    !?AddChildNodeResult
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

const TerminationContext = struct
{
    context: *TreeConstructionContext,
    pathIndex: usize = 0,
    terminatedPathIndex: ?usize = null,
    currentPosition: ast.Position,

    fn unconditionalTermination(self: *TerminationContext) bool
    {
        return !(self.terminatedPathIndex == null);
    }

    fn maybeTerminate(
        self: *TerminationContext,
        // Initiable
        action: anytype) 
            {
        defer self.pathIndex += 1;

        if (!action.initializedPointer().*)
        {
            self.terminatedPathIndex = self.pathIndex;
        }
        if (self.unconditionalTermination())
        {
            const nodeIndex = self.context.nodePath.items[self.pathIndex];
            const node = &self.context.tree.nodes.items[nodeIndex];
            node.span.endInclusive = self.currentPosition.add(.{ .bit = -1 });
            return .{
                .node = .{
                    .item = node,
                    .index = nodeIndex,
                },
                .data = if (node.nodeData) |d| NodeDataResult
                {
                    .item = &self.context.tree.nodeData[d],
                    .index = node.nodeData,
                } else null,
            };
        }
    }

    pub fn complete(self: *TerminationContext) void
    {
        if (self.terminatedPathIndex) |i|
        {
            self.context.nodePath.items.len = i;
        }
    }
};

fn getPathNode(context: *TreeConstructionContext, depth: u5)
    struct
    {
        node: NodeResult,
        data: ?NodeDataResult,
    }
{
    const nodeIndex = context.nodePath.items[self.pathIndex];
    const node = &context.tree.nodes.items[nodeIndex];
    return .{
        .node = .{
            .item = node,
            .index = nodeIndex,
        },
        .data = if (node.nodeData) |d| NodeDataResult
        {
            .item = &self.context.tree.nodeData[d],
            .index = node.nodeData,
        } else null,
    };
}


// 1. Record current depth.
// 2. Add new nodes based on the current parser state, up until depth.
// 3. Parse, stop at initialization.
// 4. Fill in the data of all nodes to be deleted. 
//    These are the ndoes before the recorded depth, 
//    and all the nodes after the first uninited node.
//    Use the tag stored in the node data to figure out 
//    the path the parser took in order to figure out which data to fill in.
//
//    OR do a finalization flag. 
//    This will allow me to keep switching on the state of the tree instead.
//
// 4. Delete extra nodes.

fn finalizeNodesForCurrentAction(
    context: *TreeConstructionContext,
    currentPosition: ast.Position) !void
{
    const maskCopy = context.levelStats.initMask.inited;
    maskCopy.toggleAll();
    const firstUninitedIndex = if (maskCopy.findFirstSet()) |i| (i + 1) else 0;

    if (firstUninitedIndex >= context.levelStats.max)
    {
        return;
    }

    const finalizedNodesMask = b: {
        // So it's gonna be all the nodes after the first finalized one,
        // But not ones that have been finalized at an earlier step.
    };

    // Switch into the current state and save data for nodes at depth >=firstUnsetBitIndex
    // TODO: This should use a visitor.
    {
        var deletionContext = struct
        {
            depth: u5,
            max: u5,

            fn push(self: *@This()) void
            {
                self.depth += 1;
            }

            fn pop(self: *@This()) void
            {
                self.depth -= 1;
            }
        }{
            .depth = 0,
            .max = context.levelStats.max,
        };

        outer: {
            var t = getPathNode(context, depth);
            switch (t.data.?.item.type)
            {
                else => unreachable,
                .TopLevel => |topLevelAction|
                {
                    if ()
                    {
                        break :outer;
                    }

                    deletionContext.push();
                    defer deletionContext.pop();
                },
            }

            std.debug.assert(depth == context.levelStats.max);
        }
    }


    for (firstUninitedIndex .. context.levelStats.max) |i|
    {
        const nodeIndex = context.nodePath.items[i];
        const node = &context.tree.nodes[nodeIndex];
        node.span.endInclusive = currentPosition.add(.{ .bit = -1 });
    }

    context.nodePath.items.len = firstUninitedIndex;
}


fn initNodesForCurrentAction(
    context: *TreeConstructionContext,
    currentPosition: ast.Position) !void
{
    const state = &context.parserState;
    
    if (try maybeAddChildToLastNode(context, state.action, currentPosition))
    {
        return;
    }

    switch (state.action)
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

            switch (chunk.action)
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

fn parseIntoTree(allocator: std.mem.Allocator) !ast.AST
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

