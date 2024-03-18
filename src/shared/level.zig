const std = @import("std");

pub const LevelInitMask = struct
{
    mask: std.bit_set.IntegerBitSet(32) = .{ .mask = 0 },

    pub fn setAtLevel(self: *LevelInitMask, level: u5, comptime set: bool) void
    {
        if (set)
        {
            self.mask.set(level);
        }
        else
        {
            self.mask.unset(level);
        }
    }

    pub fn isInitedAtLevel(self: *const LevelInitMask, level: u5) void
    {
        return self.mask.isSet(level);
    }
};

pub const LevelStats = struct
{
    initMask: LevelInitMask,
    max: u5,
};

pub const LevelContext = struct
{
    initMask: *LevelInitMask,
    current: u5,
    max: u5,

    pub fn push(self: *LevelContext) void
    {
        self.current += 1;
        self.max = @max(self.current, self.max);
    }

    pub fn pushInit(self: *LevelContext, callback: anytype) !void
    {
        self.push();
        errdefer self.pop();

        try self.initCurrent(callback);
    }

    fn currentLevel(self: *const LevelContext) u5
    {
        return self.current - 1;
    }

    fn initCurrent(self: *LevelContext, callback: anytype) !void
    {
        const level = self.currentLevel();
        if (!self.initMask.isInitedAtLevel(level))
        {
            if (@hasDecl(callback, "execute"))
            {
                try callback.execute();
            }
            else if (@TypeOf(callback) != void)
            {
                try callback();
            }
            self.initMask.setAtLevel(level, true);
        }
    }

    pub fn deinitCurrent(self: *LevelContext) void
    {
        self.initMask.setAtLevel(self.currentLevel(), false);
    }

    pub fn pop(self: *LevelContext) void
    {
        self.current -= 1;
    }

    pub fn assertPopped(self: *const LevelContext) void
    {
        std.debug.assert(self.current == 0);
    }
};

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
    context.level().deinitCurrent();
    action.* = value;
}
