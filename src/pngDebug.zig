const std = @import("std");
const parser = @import("parser/module.zig");
const pipelines = parser.pipelines;
const png = parser.png;

pub const TestReaderContext = struct
{
    reader: pipelines.Reader(std.fs.File.Reader),

    pub fn deinit(self: *TestReaderContext) void
    {
        const file = self.reader.dataProvider.context;
        file.close();
    }
};

pub fn openTestReader(allocator: std.mem.Allocator, filePath: []const u8) !TestReaderContext
{
    var file = try std.fs.openFileAbsolute(filePath, .{ .mode = .read_only, });
    errdefer file.close();

    const reader = pipelines.Reader(@TypeOf(file.reader()))
    {
        .dataProvider = file.reader(),
        .allocator = allocator,
        .preferredBufferSize = 4096, // TODO: Get optimal block size from OS.
    };
    return .{
        .reader = reader,
    };
}

