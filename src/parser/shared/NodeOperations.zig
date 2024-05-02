const std = @import("std");
const ast = @import("ast.zig");

context: *Context,
vtable: *Vtable,

const NodeOperations = @This();

pub fn createSyntaxNode(self: NodeOperations, params: SyntaxNodeCreationParams) Error!ast.NodeId
{
    const result = self.vtable.createSyntaxNode(self.context, params);
    return result;
}

pub fn completeSyntaxNode(self: NodeOperations, params: SyntaxNodeCompletionParams) Error!void
{
    const result = self.vtable.completeSyntaxNode(self.context, params);
    return result;
}

pub fn linkSemanticParent(self: NodeOperations, params: SyntaxNodeSemanticLinkParams) Error!void
{
    const result = self.vtable.linkSemanticParent(self.context, params);
    return result;
}

pub fn createNodeData(self: NodeOperations, params: NodeDataCreationParams) Error!ast.NodeDataId
{
    const result = self.vtable.createNodeData(self.context, params);
    return result;
}

pub fn setNodeDataValue(self: NodeOperations, params: NodeDataParams) Error!void
{
    const result = self.vtable.setNodeDataValue(self.context, params);
    return result;
}

pub fn create(context: anytype) NodeOperations
{
    const storage = struct
    {
        const ContextT = @TypeOf(context.*);
        const vtable = Vtable
        {
            .createSyntaxNode = ContextT.createSyntaxNode,
            .completeSyntaxNode = ContextT.completeSyntaxNode,
            .linkSemanticParent = ContextT.linkSemanticParent,
            .createNodeData = ContextT.createNodeData,
            .setNodeDataValue = ContextT.setNodeDataValue,
        };
    };
    return .{
        .vtable = &storage.vtable,
        .context = context,
    };
}

pub const Context = opaque{};

pub const SyntaxNodeCreationParams = struct
{
    start: ast.Position,
    level: usize,
    parentId: ast.NodeId,
};

pub const SyntaxNodeCompletionParams = struct
{
    id: ast.NodeId,
    endExclusive: ast.Position,
    nodeType: ast.NodeType,
    dataId: ast.NodeDataId,
};

pub const SyntaxNodeSemanticLinkParams = struct
{
    id: ast.NodeId,
    semanticParentId: ast.NodeId,
};

pub const NodeDataCreationParams = struct
{
    associatedNode: ast.NodeId = ast.invalidNodeId,
    value: ast.NodeData = .None,
};

pub const NodeDataParams = struct
{
    id: ast.NodeDataId,
    value: ast.NodeData = .None,
};

pub const Error = std.mem.Allocator.Error;

pub const Vtable = struct
{
    // Should allocate space for a node at a given level.
    // May discard the level information.
    // The returned node is to be treated as an opaque value 
    // (the caller is not to be concerned with its structure).
    createSyntaxNode: *fn(context: *Context, value: SyntaxNodeCreationParams) Error!ast.NodeId,

    // A completed node must not accept any new children nodes.
    // A completed syntax node may or may not have an associated semantic node.
    // The associated semantic node may or may not have been completed when this is called.
    // The children nodes must have been completed (to be validated).
    completeSyntaxNode: *fn(context: *Context, value: SyntaxNodeCompletionParams) Error!void,

    // The given node is to be linked with the given other existing node.
    // The other node must not be deleted before this.
    // This shows that the new node is sharing contextual information with the other node.
    linkSemanticParent: *fn(context: *Context, value: SyntaxNodeSemanticLinkParams) Error!void,

    // Creates a semantic node, associating it with the given syntax node if its id is valid.
    // The value given is the initial value and might be changed later.
    createNodeData: *fn(context: *Context, value: NodeDataCreationParams) Error!ast.NodeDataId,

    // Updates the value of a semantic node.
    setNodeDataValue: *fn(context: *Context, value: NodeDataParams) Error!void,
};

