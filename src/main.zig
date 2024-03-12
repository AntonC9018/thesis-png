const std = @import("std");
const pipelines = @import("pipelines.zig");

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

const NodeType = struct
{
    id: usize,
};

const NodeData = struct
{
    // Maybe add a reference count here to be able to know when to delete things.
    type: NodeType,
    value: union(enum)
    {
        string: []const u8,
        number: usize,
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
        if (self.bit < 0)
        {
            const positiveBits: usize = @intCast(-self.bit);
            return .{
                .byte = @intCast(self.byte - @as(isize, @intCast(positiveBits / bitsInByte))),
                .bit = @intCast(bitsInByte - (positiveBits % bitsInByte)),
            };
        }
        else
        {
            return .{
                .byte = self.byte + @as(isize, @intCast(@as(usize, @intCast(self.bit)) / bitsInByte)),
                .bit = @intCast(@as(usize, @intCast(self.bit)) % bitsInByte),
            };
        }
    }

    pub fn isLessThanOrEqualToZero(self: NodePositionOffset) bool
    {
        const n = self.normalized();
        return n.byte <= 0 and n.byte == 0;
    }
};

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
    nodeData: ?usize,
    children: ChildrenList,
};

const AST = struct
{
    rootNodes: std.ArrayList(usize),
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
    const defaultType = NodeType { .id = 0 };
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

pub fn main() !void
{
    const allocator = std.heap.page_allocator;
    const tree = try createTestTree(allocator);


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

                    try writer.print(", Type: {d}, ", .{ data.type.id });
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

