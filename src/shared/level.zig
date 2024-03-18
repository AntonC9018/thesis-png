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
    infoMasks: *LevelInfoMasks,
    current: u5,
    max: u5,
};

pub fn LevelContext(Context: type) type
{
    return struct
    {
        context: *Context,
        data: *LevelContextData,

        const Self = @This();

        pub fn infoMasks(self: *Self) *LevelInfoMasks
        {
            return self.data.infoMasks;
        }
        pub fn current(self: *Self) *u5
        {
            return self.data.current;
        }
        pub fn max(self: *Self) *u5
        {
            return self.data.max;
        }

        pub fn push(self: *Self) void
        {
            self.current().* += 1;
            self.max().* = @max(self.current().*, self.max().*);
        }

        pub fn pushInit(self: *Self, callback: anytype) !void
        {
            self.push();
            errdefer self.pop();

            try self.initialize(callback);
        }

        fn currentLevel(self: *const Self) u5
        {
            return self.current().* - 1;
        }

        fn initialize(self: *Self, callback: anytype) !void
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

        pub fn unset(self: *Self) void
        {
            const c = self.currentLevel();
            self.infoMasks().finalized.unset(c);
            self.infoMasks().init.unset(c);
        }

        pub fn pop(self: *Self) void
        {
            self.current().* -= 1;
        }

        pub fn assertPopped(self: *const Self) void
        {
            std.debug.assert(self.current().* == 0);
        }

        pub fn finalize(self: *Self) !void
        {
            self.infoMasks().finalized.set(self.currentLevel());
        }

        pub fn advance(
            self: *Self,
            action: anytype,
            value: PointedToType(@TypeOf(action))) !void
        {
            self.unset();
            action.* = value;
        }

        pub fn clearUnreached(self: *Self) void
        {
            const setMask: LevelInfoMask = .{
                .mask = (~@as(0, u32)) >> (32 - self.max()),
            };
            self.infoMasks().init.setIntersection(setMask);
            self.infoMasks().finalized.setIntersection(setMask);
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
