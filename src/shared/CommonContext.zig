const pipelines = @import("../pipelines/pipelines.zig");
const std = @import("std");
const LevelContext = @import("level.zig").LevelContext;
const Settings = @import("Settings.zig");

sequence: *pipelines.Sequence,
allocator: std.mem.Allocator,
settings: *Settings,
level: LevelContext,
