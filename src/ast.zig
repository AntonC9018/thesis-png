const std = @import("std");
const parser = @import("parser/module.zig");
const pipelines = parser.pipelines;
const zlib = parser.zlib;
const deflate = zlib.deflate;
const chunks = parser.chunks;
const ast = parser.ast;

const resourcesDir = "raylib/raylib/examples/text/resources/";

// 1. Transform parser results into tree
// 2. Draw bytes on screen
// 3. Draw image
// 4. Visualize the tree
// 5. Allow switching pages changing the current range
// 6. Deleting invisible parts of the tree
//

pub const SyntaxChildrenList = struct
{
    array: std.ArrayListUnmanaged(usize) = .{},

    pub fn len(self: *const SyntaxChildrenList) usize
    {
        return self.array.items.len;
    }
};

pub const ChunkDataNodeType = parser.ChunkType;

pub const NodeIndex = ast.NodeId;
pub const DataIndex = ast.NodeDataId;

pub const invalidNodeIndex: NodeIndex = ast.invalidNodeId;
pub const invalidDataIndex: DataIndex = ast.invalidNodeDataId;

pub const NodeType = ast.NodeType;
pub const NodeValue = ast.NodeData;

// Maybe add a reference count here to be able to know when to delete things.
pub const NodeData = ast.NodeData;

pub const SemanticListNode = struct
{
    next: NodeIndex = invalidNodeIndex,
    prev: NodeIndex = invalidNodeIndex,
};

pub const Node = struct
{
    // In case there are child nodes, includes the position of the start
    // of the first child node, and the end position of the last child node.
    // The idea is that there may be gaps in the range of the span,
    // but it does allow you to gauge the edges.
    // If there are no children, it's just the range of the node.
    span: ast.NodeSpan,

    nodeType: ast.NodeType = .Container,
    
    // Points to the root data of the semantic linked list.
    // If there's no semantic list, just points to the data.
    // There's always at least one data in that case.
    data: DataIndex = invalidDataIndex, 
    syntaxChildren: SyntaxChildrenList = .{},
    
    // This is only going to be used for the image data nodes, probably.
    semanticList: SemanticListNode = .{},
};

fn nodeIdToIndex(id: ast.NodeId) NodeIndex
{
    return id;
}
fn dataIdToIndex(id: ast.NodeDataId) DataIndex
{
    return id;
}
fn nodeIndexToId(index: NodeIndex) ast.NodeId
{
    return index;
}
fn dataIndexToId(index: DataIndex) ast.NodeDataId
{
    return index;
}

pub const AST = struct
{
    rootNodes: std.ArrayList(NodeIndex),
    syntaxNodes: std.ArrayList(Node),
    nodeDatas: std.ArrayList(NodeData),

    const NodeOperations = parser.NodeOperations;

    pub fn create(allocators:
        struct {
            rootNode: std.mem.Allocator,
            syntaxNode: std.mem.Allocator,
            nodeData: std.mem.Allocator,
        }) AST
    {
        return .{
            .rootNodes = std.ArrayList(NodeIndex).init(allocators.rootNode),
            .syntaxNodes = std.ArrayList(Node).init(allocators.syntaxNode),
            .nodeDatas = std.ArrayList(NodeData).init(allocators.nodeData),
        };
    }

    pub fn childrenAllocator(self: *AST) std.mem.Allocator
    {
        return self.syntaxNodes.allocator;
    }

    pub fn createSyntaxNode(self: *AST, params: NodeOperations.SyntaxNodeCreationParams)
        NodeOperations.Error!ast.NodeId
    {
        const childIndex = self.syntaxNodes.items.len;
        try self.syntaxNodes.append(Node
        {
            .span = .{
                .start = params.start,
                .endInclusive = params.start,
            },
        });

        const parentIndex = nodeIdToIndex(params.parentId);
        if (parentIndex == invalidNodeIndex)
        {
            std.debug.assert(params.level == 0);
            try self.rootNodes.append(childIndex);
        }
        else
        {
            const parentNode = &self.syntaxNodes.items[parentIndex];
            try parentNode.syntaxChildren.array.append(
                self.childrenAllocator(),
                childIndex);
        }

        return nodeIndexToId(childIndex);
    }

    pub fn completeSyntaxNode(self: *AST, params: NodeOperations.SyntaxNodeCompletionParams)
        NodeOperations.Error!void
    {
        const nodeIndex = nodeIdToIndex(params.id);
        const dataIndex = dataIdToIndex(params.dataId);

        // data exists?
        if (dataIndex != invalidDataIndex)
        {
            std.debug.assert(self.nodeDatas.items.len > dataIndex);
        }

        const node = &self.syntaxNodes.items[nodeIndex];
        node.span.endInclusive = end:
        {
            const comparison = params.endExclusive.compareTo(node.span.start);
            std.debug.assert(comparison >= 0);

            if (comparison == 0)
            {
                break :end node.span.start;
            }
            else
            {
                break :end params.endExclusive.add(.{ .bit = -1 });
            }
        };
        node.nodeType = params.nodeType;
        std.debug.assert(node.data == dataIndex);

        if (dataIndex != invalidDataIndex)
        {
            const data = &self.nodeDatas.items[dataIndex];
            if (data.* == .None)
            {
                std.debug.print("Data was created but is empty on node completion."
                    ++ "Something might be wrong. The node type is {}", 
                    .{ node.nodeType });
            }
        }
    }

    pub fn linkSemanticParent(self: *AST, params: NodeOperations.SyntaxNodeSemanticLinkParams)
        NodeOperations.Error!void
    {
        const nodeIndex = nodeIdToIndex(params.id);
        const parentIndex = nodeIdToIndex(params.semanticParentId);

        const child = &self.syntaxNodes.items[nodeIndex];
        std.debug.assert(child.semanticList.prev == invalidNodeIndex);
        child.semanticList.prev = parentIndex;

        if (parentIndex != invalidNodeIndex)
        {
            const parent = &self.syntaxNodes.items[parentIndex];
            std.debug.assert(parent.semanticList.next == invalidNodeIndex);
            parent.semanticList.next = nodeIndex;
        }
    }

    pub fn createNodeData(self: *AST, params: NodeOperations.NodeDataCreationParams)
        NodeOperations.Error!ast.NodeDataId
    {
        const associatedNodeIndex = nodeIdToIndex(params.associatedNode);
        const node: ?*Node = if (associatedNodeIndex == invalidNodeIndex)
                null
            else
                &self.syntaxNodes.items[associatedNodeIndex];
        if (node) |n|
        {
            // Not already created.
            std.debug.assert(n.data == invalidDataIndex);
        }

        const dataIndex = self.nodeDatas.items.len;
        const data = try self.nodeDatas.addOne();
        data.* = params.value;

        if (node) |n|
        {
            n.data = dataIndex;
        }

        return dataIndexToId(dataIndex);
    }

    pub fn setNodeDataValue(self: *AST, params: NodeOperations.NodeDataParams) 
        NodeOperations.Error!void
    {
        const dataIndex = dataIdToIndex(params.id);
        // TODO: Maybe use a multiarray.
        const data = &self.nodeDatas.items[dataIndex];
        
        // Changing the type halfway is disallowed, unless it's not been set yet.
        if (data.* != .None)
        {
            const currentTag = @intFromEnum(data.*);
            const newTag = @intFromEnum(params.value);
            std.debug.assert(currentTag == newTag);
        }

        data.* = params.value;
    }

    pub fn deinit(self: *AST, parserAllocator: std.mem.Allocator) void
    {
        for (self.nodeDatas.items) |*data|
        {
            switch (data)
            {
                .OwnedString => |s|
                {
                    s.deinit(parserAllocator);
                },
                else => {},
            }
        }
    }
};

pub fn createTestTree(allocator: std.mem.Allocator) !AST
{
    var tree: AST = .{
        .rootNodes = std.ArrayList(usize).init(allocator),
        .nodes = std.ArrayList(Node).init(allocator),
        .nodeData = std.ArrayList(NodeData).init(allocator),
    };
    const data = try tree.nodeDatas.addManyAsArray(10);
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
        try tree.syntaxNodes.append(node);
        position = endPosition;
    }
    // Make a couple nodes to serve as children.
    const childrenCount = 3;
    const parentNode = try tree.syntaxNodes.addOne();

    var children: SyntaxChildrenList = .{};
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
        const currentIndex = tree.syntaxNodes.items.len;
        try children.array.append(tree.childrenAllocator(), currentIndex);
        try tree.syntaxNodes.append(node);
        position = endPosition;
    }

    {
        const childIndices = children.array.items;
        const firstChild = childIndices[0];
        const lastChild = childIndices[childIndices.len - 1];

        const start = tree.syntaxNodes.items[firstChild].span.start;
        const end = tree.syntaxNodes.items[lastChild].span.endInclusive;
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
