const std = @import("std");
const pipelines = @import("pipelines.zig");
const parser = @import("parser/parser.zig");
const zlib = @import("zlib/zlib.zig");
const deflate = @import("zlib/deflate.zig");
const chunks = parser.chunks;

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

const NodeIndex = usize;
const DataIndex = usize;

const invalidNodeIndex: NodeIndex = parser.ast.invalidNodeId;
const invalidDataIndex: DataIndex = parser.ast.invalidDataId;

const NodeType = parser.ast.NodeType;
const NodeValue = parser.ast.NodeValue;

// Maybe add a reference count here to be able to know when to delete things.
const Data = parser.ast.NodeData;

const Node = struct
{
    // In case there are child nodes, includes the position of the start
    // of the first child node, and the end position of the last child node.
    // The idea is that there may be gaps in the range of the span,
    // but it does allow you to gauge the edges.
    // If there are no children, it's just the range of the node.
    span: parser.ast.NodeSpan,
    
    // Points to the root data of the semantic linked list.
    // If there's no semantic list, just points to the data.
    // There's always at least one data in that case.
    nodeData: ?DataIndex, 
    syntacticChildren: ChildrenList,
    
    // This is only going to be used for the image data nodes, probably.
    semanticChildrenList: struct
    {
        prev: NodeIndex = invalidNodeIndex,
        next: NodeIndex = invalidNodeIndex,
    } = .{},
};

const AST = struct
{
    rootNodes: std.ArrayList(NodeIndex),
    nodes: std.ArrayList(Node),
    nodeData: std.ArrayList(Data),

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
        .nodeData = std.ArrayList(Data).init(allocator),
    };
    const data = try tree.nodeData.addManyAsArray(10);
    const defaultType = NodeType { .TopLevel = .Chunk };
    data.*[0] = .{
        .type = defaultType,
        .value = .{
            .String = "Test",
        },
    };
    data.*[1] = .{
        .type = defaultType,
        .value = .{
            .String = "Hello world, this is a longer piece of text",
        },
    };
    for (2 .. data.len) |i|
    {
        data.*[i] = .{
            .type = defaultType,
            .value = .{
                .Number = i,
            },
        };
    }

    var position = parser.ast.Position
    {
        .byte = 0,
        .bit = 0,
    };

    {
        const endPosition = position.add(.{ .byte = 1 });
        const node = Node
        {
            .span = parser.ast.NodeSpan.fromStartAndEndExclusive(position, endPosition),
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
            .span = parser.ast.NodeSpan.fromStartAndEndExclusive(position, endPosition),
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
