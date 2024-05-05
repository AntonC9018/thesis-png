const std = @import("std");
const parser = @import("parser/module.zig");
const pipelines = parser.pipelines;
const png = parser.png;

pub const TestReaderContext = struct
{
    directory: std.fs.Dir,
    reader: pipelines.Reader(std.fs.File.Reader),

    pub fn deinit(self: *TestReaderContext) void
    {
        const file = self.reader.dataProvider.context;
        file.close();

        self.directory.close();
    }
};

pub fn openTestReader(allocator: std.mem.Allocator) !TestReaderContext
{
    var cwd = std.fs.cwd();

    var testDir = try cwd.openDir("test_data", .{ .access_sub_paths = true, });
    errdefer testDir.close();

    var file = try testDir.openFile("test.png", .{ .mode = .read_only, });
    errdefer file.close();

    const reader = pipelines.Reader(@TypeOf(file.reader()))
    {
        .dataProvider = file.reader(),
        .allocator = allocator,
        .preferredBufferSize = 4096, // TODO: Get optimal block size from OS.
    };
    return .{
        .directory = testDir,
        .reader = reader,
    };
}

