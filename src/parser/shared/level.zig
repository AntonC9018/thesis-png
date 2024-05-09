const std = @import("std");
const parser = @import("../module.zig");
const ast = parser.ast;
const pipelines = parser.pipelines;
const NodeOperations = parser.NodeOperations;

pub const LevelContextData = struct
{
    current: u5 = 0,
};

const SyntaxNodeInfo = struct
{
    nodeId: ast.NodeId,
    dataId: ast.NodeDataId = ast.invalidNodeDataId,
    nodeType: ast.NodeType = .Container,
};

pub const NodeSemanticContext = struct
{
    hierarchy: std.ArrayListUnmanaged(SyntaxNodeInfo) = .{},
};

pub const NodeContext = struct
{
    allocator: std.mem.Allocator,
    syntaxNodeStack: std.ArrayListUnmanaged(SyntaxNodeInfo) = .{},
    operations: NodeOperations,
};

pub fn LevelContext(Context: type) type
{
    return struct
    {
        context: *Context,
        data: *LevelContextData,

        const Self = @This();

        pub fn current(self: Self) *u5
        {
            return &self.data.current;
        }
        fn nodeContext(self: Self) *NodeContext
        {
            return self.context.nodeContext();
        }

        pub fn depth(self: Self) usize
        {
            return self.nodeContext().syntaxNodeStack.items.len;
        }

        fn maybeCreateSyntaxNode(self: Self) 
            NodeOperations.Error!struct
            {
                node: *SyntaxNodeInfo,
                created: bool,
            }
        {
            const nodeContext_ = self.nodeContext();
            const nodes = &nodeContext_.syntaxNodeStack;
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

                const position = self.context.getStartBytePosition();

                const newNodeId = try nodeContext_.operations.createSyntaxNode(.{
                    .level = levelIndex,
                    .parentId = parentId,
                    .start = position,
                });

                const node = try nodes.addOne(nodeContext_.allocator);
                node.* = .{
                    .nodeId = newNodeId,
                };
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
        }

        pub fn push(self: Self) !void
        {
            self.pushImpl();
            errdefer self.pop();

            _ = try self.maybeCreateSyntaxNode();
        }

        pub fn pushInit(self: Self, callback: anytype) !void
        {
            self.pushImpl();
            errdefer self.pop();

            const node = try self.maybeCreateSyntaxNode();
            if (!node.created)
            {
                return;
            }

            if (@hasDecl(@TypeOf(callback), "execute"))
            {
                try callback.execute();
            }
            else
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
            const position: ast.Position = self.context.getStartBytePosition();

            try nodeContext_.operations.completeSyntaxNode(.{
                .nodeType = node.nodeType,
                .endExclusive = position,
                .id = node.nodeId,
                .dataId = node.dataId,
            });
        }

        pub fn completeNode(self: Self) !void
        {
            const nodeContext_ = self.nodeContext();
            const nodes = &nodeContext_.syntaxNodeStack;
            const levelIndex = self.currentLevel();

            if (levelIndex >= nodes.items.len)
            {
                return;
            }

            const node = &nodes.items[levelIndex];
            if (levelIndex == nodes.items.len - 1)
            {
                try self.completeNodeAtWithoutRemoving(levelIndex);
                nodes.items.len -= 1;
            }
            else
            {
                std.debug.print("Deleting node at level {} with type {}\n", .{
                    levelIndex,
                    .{ node.nodeType },
                });
                std.debug.print("The completed node must be the last in the stack. " 
                    ++ "There have been uncompleted nodes in between:\n", .{});

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

        pub fn setDataValue(self: Self, value: ast.NodeData) !void
        {
            // TODO: Check value and node type compatibility.
            const currentNode_: *SyntaxNodeInfo = self.currentNode();
            const nodeContext_ = self.nodeContext();
            const ops = nodeContext_.operations; 
            if (currentNode_.dataId == ast.invalidNodeDataId)
            {
                const semanticNodeId = try ops.createNodeData(.{
                    .associatedNode = currentNode_.nodeId,
                    .value = value,
                });
                currentNode_.dataId = semanticNodeId;
            }
            else
            {
                try nodeContext_.operations.setNodeDataValue(.{
                    .value = value,
                    .id = currentNode_.dataId,
                });
            }
        }

        pub fn completeNodeWithValue(self: Self, value: ast.NodeData) !void
        {
            if (self.context.settings().logChunkStart)
            {
                std.debug.print("Node {} {} \n", .{ self.currentNode().nodeType, value });
            }
            try self.setDataValue(value);
            try self.completeNode();
        }

        pub fn setNodeType(self: Self, nodeType: ast.NodeType) void
        {
            self.currentNode().nodeType = nodeType;
        }

        pub fn getNodeId(self: Self) ast.NodeId
        {
            return self.currentNode().nodeId;
        }

        pub fn setSemanticParent(self: Self, parentId: ast.NodeId) !void
        {
            const currentNode_ = self.currentNode();
            try self.nodeContext().operations.linkSemanticParent(.{
                .id = currentNode_.nodeId,
                .semanticParentId = parentId,
            });
        }

        // Should save the sequence start here.
        pub fn pushNode(self: Self, nodeType: ast.NodeType) !void
        {
            self.pushImpl();
            errdefer self.pop();

            const r = try self.maybeCreateSyntaxNode();
            if (r.created)
            {
                self.setNodeType(nodeType);
            }

            std.debug.assert(std.meta.eql(r.node.nodeType, nodeType));
        }

        // Implies completing the nodes as well.
        pub fn captureSemanticContextForHierarchy(
            self: Self,
            targetContext: *NodeSemanticContext)

            std.mem.Allocator.Error!void
        {
            const nodeContext_ = self.nodeContext();
            const nodes = &nodeContext_.syntaxNodeStack.items;
            const firstChildIndex = self.current().*;
            const poppedNodes = nodes.*[firstChildIndex .. nodes.len];

            try targetContext.hierarchy.resize(
                self.context.allocator(),
                poppedNodes.len);

            const hierarchy = targetContext.hierarchy.items;
            for (hierarchy, poppedNodes) |*mem, *popped|
            {
                mem.* = popped.*;
            }

            try self.completeHierarchy();
        }

        pub fn completeHierarchy(self: Self) !void
        {
            const nodeContext_ = self.nodeContext();
            const nodes = &nodeContext_.syntaxNodeStack.items;
            const firstChildIndex = self.current().*;
            const poppedNodes = nodes.*[firstChildIndex .. nodes.len];

            for (0 .. poppedNodes.len) |i|
            {
                const nodeIndex = firstChildIndex + i;
                try self.completeNodeAtWithoutRemoving(nodeIndex);
            }

            // Pop all of the child nodes.
            nodes.len = firstChildIndex;
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
                level.pushImpl();
                const r = try level.maybeCreateSyntaxNode();
                r.node.nodeType = it.nodeType;
                r.node.dataId = it.dataId;
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
