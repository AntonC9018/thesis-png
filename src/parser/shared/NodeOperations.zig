const std = @import("std");
const ast = @import("ast.zig");

context: *Context,
vtable: *const Vtable,

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
        fn WrappedFuncType(FuncType: type) type
        {
            var info = @typeInfo(FuncType);
            const params = info.Fn.params;

            std.debug.assert(@typeInfo(params[0].type.?) == .Pointer);

            var newParams = params[0 .. params.len].*;
            newParams[0] = .{
                .is_generic = false,
                .is_noalias = false,
                .type = *Context,
            };
            
            info.Fn.params = &newParams;
            const resultFuncType = @Type(info);

            return *const resultFuncType;
        }

        fn wrappedFunc(comptime func: anytype) WrappedFuncType(@TypeOf(func))
        {
            return @ptrCast(&func);
        }

        const ContextT = @TypeOf(context.*);
        const vtable = Vtable
        {
            .createSyntaxNode = wrappedFunc(ContextT.createSyntaxNode),
            .completeSyntaxNode = wrappedFunc(ContextT.completeSyntaxNode),
            .linkSemanticParent = wrappedFunc(ContextT.linkSemanticParent),
            .createNodeData = wrappedFunc(ContextT.createNodeData),
            .setNodeDataValue = wrappedFunc(ContextT.setNodeDataValue),
        };
    };
    return .{
        .vtable = &storage.vtable,
        .context = @ptrCast(context),
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
    value: ast.NodeData,
};

pub const NodeDataParams = struct
{
    id: ast.NodeDataId,
    value: ast.NodeData,
};

pub const Error = std.mem.Allocator.Error;

pub const Vtable = struct
{
    // Should allocate space for a node at a given level.
    // May discard the level information.
    // The returned node is to be treated as an opaque value 
    // (the caller is not to be concerned with its structure).
    createSyntaxNode: *const fn(context: *Context, value: SyntaxNodeCreationParams) Error!ast.NodeId,

    // A completed node must not accept any new children nodes.
    // A completed syntax node may or may not have an associated semantic node.
    // The associated semantic node may or may not have been completed when this is called.
    // The children nodes must have been completed (to be validated).
    completeSyntaxNode: *const fn(context: *Context, value: SyntaxNodeCompletionParams) Error!void,

    // The given node is to be linked with the given other existing node.
    // The other node must not be deleted before this.
    // This shows that the new node is sharing contextual information with the other node.
    linkSemanticParent: *const fn(context: *Context, value: SyntaxNodeSemanticLinkParams) Error!void,

    // Creates a semantic node, associating it with the given syntax node if its id is valid.
    // The value given is the initial value and might be changed later.
    createNodeData: *const fn(context: *Context, value: NodeDataCreationParams) Error!ast.NodeDataId,

    // Updates the value of a node's data.
    setNodeDataValue: *const fn(context: *Context, value: NodeDataParams) Error!void,
};

