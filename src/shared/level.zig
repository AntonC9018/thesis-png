const std = @import("std");

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

        pub fn push(self: Self) void
        {
            self.current().* += 1;
            self.max().* = @max(self.current().*, self.max().*);
        }

        pub fn pushInit(self: Self, callback: anytype) !void
        {
            self.push();
            errdefer self.pop();

            try self.initialize(callback);
        }

        fn currentLevel(self: Self) u5
        {
            return self.current().* - 1;
        }

        fn initialize(self: Self, callback: anytype) !void
        {
            const level = self.currentLevel();
            if (!self.infoMasks().init.isSet(level))
            {
                if (@hasDecl(callback, "execute"))
                {
                    try callback.execute();
                }
                else if (@TypeOf(callback) != void)
                {
                    try callback();
                }
                self.infoMasks().init.set(level);
            }
        }

        pub fn unset(self: Self) void
        {
            const c = self.currentLevel();
            self.infoMasks().finalized.unset(c);
            self.infoMasks().init.unset(c);
        }

        pub fn pop(self: Self) void
        {
            self.current().* -= 1;
        }

        pub fn assertPopped(self: Self) void
        {
            std.debug.assert(self.current().* == 0);
        }

        pub fn finalize(self: Self) !void
        {
            self.infoMasks().finalized.set(self.currentLevel());
        }

        pub fn advance(
            self: Self,
            action: anytype,
            value: PointedToType(@TypeOf(action))) !void
        {
            self.unset();
            action.* = value;
        }

        pub fn clearUnreached(self: Self) void
        {
            const setMask: LevelInfoMask = .{
                .mask = (~@as(0, u32)) >> (32 - self.max()),
            };
            self.infoMasks().init.setIntersection(setMask);
            self.infoMasks().finalized.setIntersection(setMask);
        }

        // This has to be moved.
        const ast = @import("../parser/ast.zig");

        pub fn completeNode(self: Self) void
        {
            // Should set the sequence end here.
            _ = self;
        }

        pub fn completeNodeWithValue(self: Self, value: ast.NodeValue)
            !struct
            {
                nodeId: ast.NodeId,
                dataId: ast.DataId,
            }
        {
            self.completeNode();
            std.debug.print("Node {} \n", .{ value });
            return .{
                .nodeId = 0,
                .dataId = 0,
            };
        }

        // If the semantic node is already set, this does nothing.
        pub fn maybeCreateSemanticNode(self: Self, nodeType: ast.NodeType) !ast.NodeId
        {
            _ = self;
            std.debug.print("Node {}", .{ nodeType });
            return 0;
        }

        pub fn setSemanticParent(self: Self, parentId: ast.DataId) !ast.NodeId
        {
            _ = self;
            std.debug.print("Node {}", .{ parentId });
            return 0;
        }

        // Should save the sequence start here.
        pub fn pushNodeData(self: Self, nodeType: ast.NodeType) !ast.NodeId
        {
            const t = struct
            {
                level: Self,
                nodeType_: ast.NodeType,

                pub fn execute(s: *@This()) !void
                {
                    s.level.maybeCreateSemanticNode(s.nodeType_);
                }
            }{
                .level = self,
                .nodeType_ = nodeType,
            };

            try self.pushInit(t);
        }

        pub fn completeNodesInHierarchy(self: Self) !void
        {
            var levelData = self.data.*;
            const level = Self
            {
                .context = self.context,
                .data = &levelData,
            };

            while (level.current() != level.max())
            {
                level.push();
                level.completeNode();
            }
        }

        pub fn captureSemanticContextForHierarchy(
            self: Self,
            targetContext: *ast.NodeSemanticContext)

            std.mem.Allocator.Error!void
        {
            var levelData = self.data.*;
            const level = Self
            {
                .context = self.context,
                .data = &levelData,
            };
            _ = level;

            const len = self.max() - self.current();
            try targetContext.semanticNodeIds.resize(len);

            for (targetContext.semanticNodeIds.items) |*it|
            {
                levelData.current += 1;
                // TODO: Copy the semantic id at that level.
                it.* = 0;
            }
        }

        pub fn applySemanticContextForHierarchy(
            self: Self,
            target: ast.NodeSemanticContext) void
        {
            var levelData = self.data.*;
            const level = Self
            {
                .context = self.context,
                .data = &levelData,
            };
            for (target.semanticNodeIds.items) |it|
            {
                level.push();
                level.setSemanticParent(it);
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
