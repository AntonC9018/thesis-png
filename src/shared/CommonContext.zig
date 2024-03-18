const pipelines = @import("../pipelines/pipelines.zig");
const std = @import("std");
const LevelContextData = @import("level.zig").LevelContextData;
const Settings = @import("Settings.zig");

sequence: *pipelines.Sequence,
allocator: std.mem.Allocator,
settings: *Settings,
level: LevelContextData,
