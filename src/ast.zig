const std = @import("std");
const parser = @import("parser/module.zig");
const pipelines = parser.pipelines;
const zlib = parser.zlib;
const deflate = zlib.deflate;
const chunks = parser.chunks;
const ast = parser.ast;
const TaggedArrayList = @import("TaggedArrayList.zig").TaggedArrayList;

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

pub const invalidNodeIndex: NodeIndex = ast.invalidNodeId;
pub const invalidDataId: DataId = @bitCast(@as(usize, std.math.maxInt(usize)));

pub fn isDataIdInvalid(id: DataId) bool
{
    return @as(usize, @bitCast(id)) == @as(usize, std.math.maxInt(usize));
}
pub fn isDataIdValid(id: DataId) bool
{
    return !isDataIdInvalid(id);
}

pub const NodeType = ast.NodeType;
pub const NodeValue = ast.NodeData;

// Maybe add a reference count here to be able to know when to delete things.
pub const NodeData = ast.NodeData;
pub const DataId = TaggedArrayList(NodeData).Id;

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
    data: DataId = invalidDataId, 
    syntaxChildren: SyntaxChildrenList = .{},
    
    // This is only going to be used for the image data nodes, probably.
    semanticList: SemanticListNode = .{},
};

fn nodeIdToIndex(id: ast.NodeId) NodeIndex
{
    return id;
}
fn decodeDataId(id: ast.NodeDataId) DataId
{
    return @bitCast(id);
}
fn nodeIndexToId(index: NodeIndex) ast.NodeId
{
    return index;
}
fn encodeDataId(id: DataId) ast.NodeDataId
{
    return @bitCast(id);
}

pub const AST = struct
{
    rootNodes: std.ArrayList(NodeIndex),
    syntaxNodes: std.ArrayList(Node),
    nodeDatas: TaggedArrayList(NodeData),

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
            .nodeDatas = TaggedArrayList(NodeData).init(allocators.nodeData),
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
                .endExclusive = params.start,
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
        const dataIndex = decodeDataId(params.dataId);

        const node = &self.syntaxNodes.items[nodeIndex];
        node.span.endExclusive = end:
        {
            const comparison = params.endExclusive.compareTo(node.span.start);
            std.debug.assert(comparison >= 0);

            if (comparison == 0)
            {
                break :end node.span.start;
            }
            else
            {
                break :end params.endExclusive;
            }
        };
        node.nodeType = params.nodeType;
        std.debug.assert(node.data.eql(dataIndex));
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
            std.debug.assert(n.data.eql(invalidDataId));
        }

        const dataId = try self.nodeDatas.append(params.value);
        if (node) |n|
        {
            n.data = dataId;
        }

        return encodeDataId(dataId);
    }

    pub fn setNodeDataValue(self: *AST, params: NodeOperations.NodeDataParams) 
        NodeOperations.Error!void
    {
        const dataId = decodeDataId(params.id);
        const data = self.nodeDatas.get(dataId);
        
        // Changing the type halfway is disallowed, unless it's not been set yet.
        {
            const currentTag = @intFromEnum(data);
            const newTag = @intFromEnum(params.value);
            std.debug.assert(currentTag == newTag);
        }

        self.nodeDatas.set(dataId, params.value);
    }

    pub fn deinit(self: *AST, parserAllocator: std.mem.Allocator) void
    {
        for (self.nodeDatas.items(.OwnedString)) |*s|
        {
            s.deinit(parserAllocator);
        }
    }
};

