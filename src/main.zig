const std = @import("std");

const pipelines = @import("pipelines.zig");
test
{ 
    _ = pipelines;
    _ = @import("zlib/zlib.zig");
}

const parser = @import("parser.zig");

pub fn main() !void
{
    var cwd = std.fs.cwd();

    var testDir = try cwd.openDir("test_data", .{ .access_sub_paths = true, });
    defer testDir.close();

    var file = try testDir.openFile("test.png", .{ .mode = .read_only, });
    defer file.close();

    const allocator = std.heap.page_allocator;
    var reader = pipelines.Reader(@TypeOf(file.reader()))
    {
        .dataProvider = file.reader(),
        .allocator = allocator,
        .preferredBufferSize = 4096, // TODO: Get optimal block size from OS.
    };
    defer reader.deinit();

    var parserState = parser.createParserState();
    var chunks = std.ArrayList(parser.ChunkNode).init(allocator);
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
            const remaining = context.sequence.len();
            if (remaining > 0)
            {
                std.debug.print("Not all input consumed. Remaining length: {}\n", .{remaining});
            }

            if (!parser.isParserStateTerminal(context.state))
            {
                std.debug.print("Ended in a non-terminal state.\n", .{});
            }

            break;
        }

        try reader.advance(context.sequence.start());
    }

    for (chunks.items) |*chunk| 
    {
        std.debug.print("Chunk(Length: {d}, Type: {s}, CRC: {x})\n", .{
            chunk.byteLength,
            chunk.chunkType.bytes,
            chunk.crc.value,
        });

        const knownChunkType = parser.getKnownDataChunkType(chunk.chunkType);
        switch (knownChunkType)
        {
            .ImageHeader =>
            {
                std.debug.print("  {any}\n", .{ chunk.dataNode.data.ihdr });
            },
            .Palette =>
            {
                std.debug.print("  {any}\n", .{ chunk.dataNode.data.plte.colors.items });
            },
            .Gamma =>
            {
                std.debug.print("  {any}\n", .{ chunk.dataNode.data.gamma });
            },
            .Text =>
            {
                std.debug.print("  {any}\n", .{ chunk.dataNode.data.text });
            },
            .Transparency =>
            {
                std.debug.print("  {any}\n", .{ chunk.dataNode.data.transparency });
            },
            else => {},
        }
    }
}

fn doMaximumAmountOfParsing(
    context: *parser.Context,
    nodes: *std.ArrayList(parser.ChunkNode)) !void
{
    while (true)
    {
        const isDone = try parser.parseTopLevelNode(context);
        if (!isDone)
        {
            continue;
        }

        switch (context.state.action)
        {
            .Signature => 
            {
                std.debug.print("Signature\n", .{});
            },
            .Chunk =>
            {
                const newItem = try nodes.addOne();
                newItem.* = context.state.chunk.node;
            },
            .StartChunk => unreachable,
        }

        context.state.action = .StartChunk;
        if (context.state.isEnd)
        {
            return;
        }
    }
}
