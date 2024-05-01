const std = @import("std");
const parser = @import("../module.zig");
const ast = parser.ast;
const pipelines = parser.pipelines;

pub const LevelInfoMask = std.bit_set.IntegerBitSet(32);

pub const LevelInfoMasks = struct
{
    init: LevelInfoMask = .{ .mask = 0 },
    finalized: LevelInfoMask = .{ .mask = 0 },
};

pub const LevelStats = struct
{
    initMask: LevelInfoMasks,
    max: u5,
};

pub const LevelContextData = struct
{
    data: *LevelStats,
    current: u5,

    pub fn infoMasks(self: LevelContextData) *LevelInfoMasks
    {
        return &self.data.initMask;
    }

    pub fn max(self: LevelContextData) *u5
    {
        return &self.data.max;
    }
};

const NodeOperationsContext = opaque{};

pub const SyntaxNodeCreationContext = struct
{
    start: ast.Position,
    level: usize,
    parentId: ast.NodeId,
};

pub const SyntaxNodeCompletionContext = struct
{
    id: ast.NodeId,
    endExclusive: ast.Position,
    nodeType: ast.NodeType,
};

pub const SyntaxNodeSemanticLinkContext = struct
{
    id: ast.NodeId,
    semanticParentId: ast.NodeId,
};

pub const SemanticNodeCreationContext = struct
{
    associatedNode: ast.NodeId = ast.invalidNodeId,
    value: ast.NodeValue = .None,
};

pub const SemanticNodeContext = struct
{
    id: ast.SemanticNodeId,
    value: ast.NodeValue = .None,
};

const NodeOperationsError = std.mem.Allocator.Error;

const NodeOperationsVtable = struct
{
    // Should allocate space for a node at a given level.
    // May discard the level information.
    // The returned node is to be treated as an opaque value 
    // (the caller is not to be concerned with its structure).
    createSyntaxNode: fn(context: *NodeOperationsContext, value: SyntaxNodeCreationContext) NodeOperationsError!ast.NodeId,

    // A completed node must not accept any new children nodes.
    // A completed syntax node may or may not have an associated semantic node.
    // The associated semantic node may or may have been completed when this is called.
    // The children nodes must have been completed (to be validated).
    completeSyntaxNode: fn(context: *NodeOperationsContext, value: SyntaxNodeCompletionContext) NodeOperationsError!void,

    // The given node is to be linked with the given other existing node.
    // The other node must not be deleted before this.
    // This shows that the new node is sharing contextual information with the other node.
    linkSemanticParent: fn(context: *NodeOperationsContext, value: SyntaxNodeSemanticLinkContext) NodeOperationsError!void,

    // Creates a semantic node, associating it with the given syntax node if its id is valid.
    // The value given is the initial value and might be changed later.
    createSemanticNode: fn(context: *NodeOperationsContext, value: SemanticNodeCreationContext) NodeOperationsError!ast.SemanticNodeId,

    // Updates the value of a semantic node.
    setSemanticNodeValue: fn(context: *NodeOperationsContext, value: SemanticNodeContext) NodeOperationsError!void,
};

const NodeOperations = struct
{
    context: *NodeOperationsContext,
    vtable: *NodeOperationsVtable,

    pub fn createNode(self: NodeOperations, value: SyntaxNodeCreationContext) NodeOperationsError!ast.NodeId
    {
        const result = self.vtable.createNode(self.context, value);
        return result;
    }

    pub fn completeNode(self: NodeOperations, value: SyntaxNodeCompletionContext) NodeOperationsError!void
    {
        const result = self.vtable.completeNode(self.context, value);
        return result;
    }

    pub fn linkSemanticParent(self: NodeOperations, value: SyntaxNodeSemanticLinkContext) NodeOperationsError!void
    {
        const result = self.vtable.linkSemanticParent(self.context, value);
        return result;
    }

    pub fn createSemanticNode(self: NodeOperations, value: SemanticNodeCreationContext) NodeOperationsError!ast.SemanticNodeId
    {
        const result = self.vtable.createSemanticNode(self.context, value);
        return result;
    }

    pub fn setSemanticNodeValue(self: NodeOperations, value: SemanticNodeContext) NodeOperationsError!void
    {
        const result = self.vtable.setSemanticNodeValue(self.context, value);
        return result;
    }
};

pub fn createNodeOperations(context: anytype) NodeOperations
{
    const Context = @TypeOf(context.*);
    const vtable = NodeOperationsVtable
    {
        .createNode = Context.createNode,
        .completeNode = Context.completeNode,
        .linkSemanticParent = Context.linkSemanticParent,
        .createSemanticNode = Context.createSemanticNode,
        .setSemanticNodeValue = Context.setSemanticNodeValue,
    };
    return .{
        .vtable = vtable,
        .context = context,
    };
}

const SyntaxNodeInfo = struct
{
    nodeId: ast.NodeId,
    semanticNodeId: ast.SemanticNodeId = ast.invalidSemanticNodeId,
    nodeType: ast.NodeType = .Container,
};

pub const NodeSemanticContext = struct
{
    hierarchy: std.ArrayList(SyntaxNodeInfo) = .{},
};

const NodeContext = struct
{
    allocator: std.mem.Allocator,
    syntaxNodeStack: std.ArrayListUnmanaged(SyntaxNodeInfo),
    operations: NodeOperations,
};

pub fn LevelContext(Context: type) type
{
    return struct
    {
        context: *Context,
        data: *LevelContextData,

        const Self = @This();

        pub fn infoMasks(self: Self) *LevelInfoMasks
        {
            return self.data.infoMasks();
        }
        pub fn current(self: Self) *u5
        {
            return self.data.current;
        }
        pub fn max(self: Self) *u5
        {
            return self.data.max();
        }
        fn nodeContext(self: Self) *NodeContext
        {
            return self.context.nodeContext;
        }

        fn maybeCreateSyntaxNode(self: Self) 
            NodeOperationsError!struct
            {
                node: *SyntaxNodeInfo,
                created: bool,
            }
        {
            const nodeContext_ = self.nodeContext();
            const nodes = nodeContext_.syntaxNodeStack;
            const levelIndex = self.currentLevel();

            if (levelIndex > nodes.items.len)
            {
                unreachable;
            }

            if (levelIndex == nodes.items.len)
            {
                const parentId = if (levelIndex == 0)
                        ast.invalidNodeId
                    else
                        nodes.items[levelIndex - 1].nodeId;

                const position = self.context.getCurrentPosition();

                const newNodeId = try nodeContext_.operations.createNode(.{
                    .level = levelIndex,
                    .parentId = parentId,
                    .start = position,
                });

                const node = try nodes.addOne(nodeContext_.allocator, .{
                    .nodeId = newNodeId,
                });
                return .{
                    .node = node,
                    .created = true,
                };
            }

            return .{
                .node = &nodes.items[levelIndex],
                .created = false,
            };
        }

        fn pushImpl(self: Self) void
        {
            self.current().* += 1;
            self.max().* = @max(self.current().*, self.max().*);
        }

        pub fn push(self: Self) !void
        {
            self.pushImpl();
            errdefer self.pop();

            _ = self.maybeCreateSyntaxNode(.None);
        }

        pub fn pushInit(self: Self, callback: anytype) !void
        {
            self.pushImpl();
            errdefer self.pop();

            const node = self.maybeCreateSyntaxNode(.None);
            if (!node.created)
            {
                return;
            }

            if (@hasDecl(callback, "execute"))
            {
                try callback.execute();
            }
            else if (@TypeOf(callback) != void)
            {
                try callback();
            }
        }

        fn currentLevel(self: Self) u5
        {
            return self.current().* - 1;
        }

        fn currentNode(self: Self) *SyntaxNodeInfo
        {
            return &self.nodeContext().syntaxNodeStack.items[self.currentLevel()];
        }

        pub fn pop(self: Self) void
        {
            self.current().* -= 1;
        }

        pub fn assertPopped(self: Self) void
        {
            std.debug.assert(self.current().* == 0);
        }

        fn completeNodeAtWithoutRemoving(self: Self, index: usize) !void
        {
            const nodeContext_ = self.nodeContext();
            const node = &nodeContext_.syntaxNodeStack.items[index];
            const position: ast.Position = self.getCurrentPosition();

            try nodeContext_.operations.completeNode(.{
                .nodeType = node.nodeType,
                .endExclusive = position,
                .id = node.nodeId,
            });
        }

        pub fn completeNode(self: Self) !void
        {
            const nodeContext_ = self.nodeContext();
            const nodes = &nodeContext_.syntaxNodeStack;
            const levelIndex = self.currentLevel();
            const node = &nodes.items[levelIndex];

            if (levelIndex == nodes.items.len - 1)
            {
                try self.completeNodeAtWithoutRemoving(levelIndex);
                nodes.items.len -= 1;
            }
            else
            {
                std.debug.print("The completed node must be the last in the stack." 
                    ++ "There have been uncompleted nodes in between:\n", .{});

                std.debug.print("Deleting node at level {} with type {}\n", .{
                    levelIndex,
                    node.nodeType,
                });

                std.debug.print("Undeleted nodes below are:\n", .{});

                for (levelIndex + 1 .. nodes.items.len) |i|
                {
                    const childNode = &nodes.items[i];
                    std.debug.print("Node at level {} with type {}\n", .{
                        i,
                        childNode.nodeType,
                    });
                }

                unreachable;
            }
        }

        pub fn setSemanticValue(self: Self, value: ast.NodeValue) !void
        {
            // TODO: Check value and type compatibility.
            const currentNode_: *SyntaxNodeInfo = self.currentNode();
            const nodeContext_ = self.nodeContext();
            const ops = nodeContext_.operations; 
            if (currentNode_.semanticNodeId == ast.invalidSemanticNodeId)
            {
                const semanticNodeId = ops.createSemanticNode(.{
                    .associatedNode = currentNode_.nodeId,
                    .value = value,
                });
                currentNode_.semanticNodeId = semanticNodeId;
            }
            else
            {
                nodeContext_.operations.setSemanticNodeValue(.{
                    .value = value,
                    .id = currentNode_.semanticNodeId,
                });
            }
        }

        pub fn completeNodeWithValue(self: Self, value: ast.NodeValue) !void
        {
            std.debug.print("Node {} \n", .{ value });
            try self.setSemanticValue(value);
            try self.completeNode();
        }

        pub fn setNodeType(self: Self, nodeType: ast.NodeType) !void
        {
            self.currentNode().nodeType = nodeType;
        }

        pub fn setSemanticParent(self: Self, parentId: ast.NodeId) !ast.NodeId
        {
            const currentNode_ = self.currentNode();
            try self.nodeContext().operations.linkSemanticParent(.{
                .id = currentNode_.nodeId,
                .semanticParentId = parentId,
            });
            return 0;
        }

        // Should save the sequence start here.
        pub fn pushNode(self: Self, nodeType: ast.NodeType) !ast.NodeId
        {
            self.pushImpl();
            errdefer self.pop();

            const r = try self.maybeCreateSyntaxNode();
            if (r.created)
            {
                r.node.nodeType = nodeType;
                return;
            }

            std.debug.assert(r.node.nodeType == nodeType);
        }

        // Implies completing the nodes as well.
        pub fn captureSemanticContextForHierarchy(
            self: Self,
            targetContext: *NodeSemanticContext)

            std.mem.Allocator.Error!void
        {
            const nodeContext_ = self.nodeContext();
            const levelIndex = self.currentLevel();
            const firstChildLevelIndex = levelIndex + 1;
            const levelCount = self.max().*;
            const nodeCountAfterThis = levelCount - firstChildLevelIndex;

            try targetContext.hierarchy.resize(nodeCountAfterThis);

            {
                const hierarchy = targetContext.hierarchy.items;
                const nodes = nodeContext_.syntaxNodeStack.items;
                for (0 .. nodeCountAfterThis) |i|
                {
                    const nodeIndex = firstChildLevelIndex + i;
                    hierarchy[i] = nodes[nodeIndex];

                    self.completeNodeAtWithoutRemoving(nodeIndex);
                }

            }
            {
                // Pop all of the child nodes.
                nodeContext_.syntaxNodeStack.items.len = firstChildLevelIndex;
            }
        }

        pub fn applySemanticContextForHierarchy(
            self: Self,
            target: NodeSemanticContext) !void
        {
            var levelData = self.data.*;
            const level = Self
            {
                .context = self.context,
                .data = &levelData,
            };

            const hierarchy = target.hierarchy.items;

            // Create new nodes as deep as the stored hierarchy.
            for (hierarchy) |it|
            {
                try level.pushImpl();
                const r = try level.maybeCreateSyntaxNode();
                r.node.nodeType = it.nodeType;
                r.node.semanticNodeId = it.semanticNodeId;
                try level.setSemanticParent(it.nodeId);
            }
        }
    };
}

fn PointedToType(t: type) type
{
    const info = @typeInfo(t);
    return info.Pointer.child;
}

pub fn advanceAction(
    context: anytype,
    action: anytype,
    value: PointedToType(@TypeOf(action))) void
{
    context.level().unsetCurrent();
    action.* = value;
}
