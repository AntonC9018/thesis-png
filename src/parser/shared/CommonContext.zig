const parser = @import("../module.zig");
const pipelines = parser.pipelines;
const std = @import("std");
const LevelContextData = parser.level.LevelContextData;
const Settings = parser.Settings;

sequence: *pipelines.Sequence,
allocator: std.mem.Allocator,
settings: *Settings,
nodeContext: *parser.level.NodeContext,
level: LevelContextData = .{},
