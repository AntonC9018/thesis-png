const std = @import("std");
const parser = @import("parser/parser.zig");
const pipelines = @import("pipelines.zig");

pub const TestReaderContext = struct
{
    directory: std.fs.Dir,
    reader: pipelines.Reader(@TypeOf(std.fs.File.Reader)),

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

pub fn readTestFile() !void
{
    const allocator = std.heap.page_allocator;
    var readerContext = try openTestReader(allocator);
    defer readerContext.deinit();

    const reader = &readerContext.reader;

    var parserState = parser.createParserState();
    var chunks = std.ArrayList(parser.Chunk).init(allocator);
    const settings = parser.Settings
    {
        .logChunkStart = true,
    };

    outerLoop: while (true)
    {
        var readResult = try reader.read();
        var context = parser.Context
        { 
            .state = &parserState,
            .sequence = &readResult.sequence,
            .allocator = allocator,
            .settings = &settings,
        };

        doMaximumAmountOfParsing(&context, &chunks)
        catch |err|
        {
            const errorStream = std.io.getStdErr();
            try parser.printStepName(errorStream.writer(), context.state);

            const isNonRecoverableError = e:
            {
                switch (err)
                {
                    error.NotEnoughBytes => break :e false,
                    error.SignatureMismatch => 
                    {
                        std.debug.print("Signature mismatch\n", .{});
                        break :e true;
                    },
                    error.LengthValueTooLarge => 
                    {
                        std.debug.print("Length too large\n", .{});
                        break :e true;
                    },
                    else => |_| 
                    {
                        std.debug.print("Some other error: {}\n", .{err});
                        break :e true;
                    },
                }
            };

            if (isNonRecoverableError)
            {
                break :outerLoop;
            }
        };

        if (readResult.isEnd)
        {
            const remaining = context.sequence().len();
            if (remaining > 0)
            {
                std.debug.print("Not all input consumed. Remaining length: {}\n", .{remaining});
            }

            if (!parser.isStateTerminal(context.state))
            {
                std.debug.print("Ended in a non-terminal state.\n", .{});
            }

            break;
        }

        try reader.advance(context.sequence().start());
    }

    for (chunks.items) |*chunk| 
    {
        std.debug.print("Chunk(Length: {d}, Type: {s}, CRC: {x})\n", .{
            chunk.dataByteLen,
            chunk.type.getString(),
            chunk.crc.value,
        });

        switch (chunk.type)
        {
            .ImageHeader =>
            {
                std.debug.print("  {any}\n", .{ chunk.data.imageHeader });
            },
            .Palette =>
            {
                std.debug.print("  {any}\n", .{ chunk.data.palette.colors.items });
            },
            .Gamma =>
            {
                std.debug.print("  {any}\n", .{ chunk.data.gamma });
            },
            .Text =>
            {
                std.debug.print("  {any}\n", .{ chunk.data.text });
            },
            .Transparency =>
            {
                std.debug.print("  {any}\n", .{ chunk.data.transparency });
            },
            else => {},
        }
    }
}

fn doMaximumAmountOfParsing(
    context: *parser.Context,
    nodes: *std.ArrayList(parser.Chunk)) !void
{
    while (true)
    {
        const currentlyParsing = context.state.action.key;
        const isDone = try parser.parseTopLevelItem(context);
        if (!isDone)
        {
            continue;
        }

        switch (currentlyParsing)
        {
            .Signature => 
            {
                std.debug.print("Signature\n", .{});
            },
            .Chunk =>
            {
                const newItem = try nodes.addOne();
                newItem.* = context.state.chunk.object;
            },
        }

        if (context.state.isEnd)
        {
            return;
        }
    }
}
