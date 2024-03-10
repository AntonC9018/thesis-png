const std = @import("std");
const parser = @import("parser.zig");
const pipelines = @import("pipelines.zig");

pub fn main() !void
{
    try @import("pngDebug.zig").readTestFile();
}

test
{ 
    _ = pipelines;
    _ = @import("zlib/zlib.zig");
}

