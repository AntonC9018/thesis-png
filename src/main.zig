const std = @import("std");
const parser = @import("parser/module.zig");
const png = parser.png;

const debug = @import("pngDebug.zig");
const ast = @import("ast.zig");

const pipelines = parser.pipelines;
const ByteRange = pipelines.ByteRange;

const AppContext = struct
{
    bufferManager: pipelines.BufferManager,
    tree: ast.AST,
};

fn parseIntoTree(allocator: std.mem.Allocator) !AppContext
{
    var testContext = try debug.openTestReader(allocator);
    defer testContext.deinit();

    const reader = &testContext.reader;

    // We want to keep the whole file in memory for the operations after.
    // It's not optimal, we'd want to load parts of the file out of memory.
    // Maybe do that later?
    reader.buffer().lowerLimitHint = 0;

    var parserState = png.createParserState();
    const parserSettings = png.Settings
    {
        .logChunkStart = true,
    };

    var tree = ast.AST.create(.{
        .nodeData = allocator,
        .rootNode = allocator,
        .syntaxNode = allocator,
    });
    var nodeContext = parser.NodeContext
    {
        .allocator = allocator,
        .operations = parser.NodeOperations.create(&tree),
    };

    var context = png.Context
    {
        .common = .{
            .allocator = allocator,
            .nodeContext = &nodeContext,
            .settings = &parserSettings,
            .sequence = undefined,
        },
        .state = &parserState,
    };
    defer
    {
        // Complete all of the nodes in case the tree is returned while there's an error.
    }

    outerLoop: while (true)
    {
        std.debug.print("Reading sequence\n", .{});
        const readResult = reader.read() catch unreachable;

        var sequence = readResult.sequence;
        context.common.sequence = &sequence;

        innerLoop: while (true)
        {
            defer context.level().assertPopped();

            const isDone = png.parseNextItem(&context) catch |err|
            {
                if (err != error.NotEnoughBytes)
                {
                    std.debug.print("Non recoverable error {}", .{ err });
                    break :outerLoop;
                }

                break :innerLoop;
            };
            if (isDone and sequence.len() == 0)
            {
                break :innerLoop;
            }
        }

        if (readResult.isEnd)
        {
            const remaining = sequence.len();
            if (remaining > 0)
            {
                std.debug.print("Not all input consumed. Remaining length: {}\n", .{remaining});
            }

            if (!png.isStateTerminal(&context))
            {
                std.debug.print("Ended in a non-terminal state.\n", .{});
            }

            break :outerLoop;
        }

        try reader.advance(sequence.start());
    }

    try context.level().completeHierarchy();
    context.level().assertPopped();

    return .{
        .tree = tree,
        .bufferManager = reader._buffer,
    };
}

fn toHexChar(ch: u4) u8
{
    return switch (ch)
    {
        0 ... 9 => @as(u8, ch) + '0',
        0xA ... 0xF => @as(u8, ch) - 0xA + 'A',
    };
}

const RangeSize = struct
{
    rows: usize,
    cols: usize,

    pub fn byteCount(self: RangeSize) usize
    {
        return self.rows * self.cols;
    }

    pub fn getRangeCount(
        range: RangeSize,
        totalSize: usize) usize
    {
        return totalSize / range.byteCount();
    }

    pub fn computeRange(
        self: RangeSize,
        index: usize) ByteRange
    {
        const t = self.byteCount();
        return .{
            .start = index * t,
            .end = (index + 1) * t,
        };
    }
};

fn componentwiseMult(v1: raylib.Vector2, v2: raylib.Vector2) raylib.Vector2
{
    return .{
        .x = v1.x * v2.x,
        .y = v1.y * v2.y,
    };
}

const raylib = @import("raylib");

pub fn main() !void
{
    const allocator = std.heap.page_allocator;
    var appContext = try parseIntoTree(allocator);

    var rangeSize = RangeSize
    {
        .rows = 10,
        .cols = 10,
    };
    var rangeIndex: usize = 0;
    var clickedPosition: ?raylib.Vector2i = null;

    var tempBuffer = std.ArrayList(u8).init(allocator);
    defer tempBuffer.deinit();

    raylib.SetConfigFlags(.{ .FLAG_WINDOW_RESIZABLE = true });
    raylib.InitWindow(1200, 1200, "hello world!");
    raylib.SetTargetFPS(60);

    defer raylib.CloseWindow();

    const fontSize = 32;
    const fontTtf = raylib.LoadFontEx("resources/monofonto.otf", fontSize, null, 250);

    while (!raylib.WindowShouldClose())
    {
        raylib.BeginDrawing();
        defer raylib.EndDrawing();
        
        raylib.ClearBackground(raylib.BLACK);

        {
            const newIndex = newIndex:
            {
                if (raylib.IsKeyPressed(.KEY_EQUAL))
                {
                    break :newIndex @min(rangeIndex + 1, rangeSize.getRangeCount(appContext.bufferManager.totalBytes));
                }
                if (raylib.IsKeyPressed(.KEY_MINUS))
                {
                    break :newIndex rangeIndex -| 1;
                }
                break :newIndex rangeIndex;
            };
            if (newIndex != rangeIndex)
            {
                rangeIndex = newIndex;
                clickedPosition = null;
            }
        }

        const range = rangeSize.computeRange(rangeIndex);
        const sequence = appContext.bufferManager.getSegmentForRange(range);

        // position -> node -- simple search
        // build up a path of node ids
        // draw the information


        // draw the bytes
        // We know and we want the font to be monospace.
        const textSpacing = 0;
        const byteTextSize = raylib.MeasureTextEx(fontTtf, "00", fontSize, textSpacing);
        const byteSpacing = raylib.Vector2
        {
            .x = textSpacing + 10,
            .y = textSpacing,
        };
        const byteTextSizePadded = byteTextSize.add(byteSpacing);

        {
            var lineIndex: usize = 0;
            var colIndex: usize = 0;

            var iter = sequence.iterate().?;
            while (true)
            {
                const bytes = iter.current();

                for (bytes) |b|
                {
                    std.debug.assert(colIndex < rangeSize.cols and lineIndex < rangeSize.rows);

                    const cellPos = raylib.Vector2
                    {
                        .x = @floatFromInt(colIndex),
                        .y = @floatFromInt(lineIndex),
                    };
                    const pos = componentwiseMult(cellPos, byteTextSizePadded);

                    const hexString = hexString: {
                        var result: [2:0]u8 = undefined;
                        result[2] = 0;

                        const firstHalf: u4 = @intCast(b & 0x0F);
                        const secondHalf: u4 = @intCast((b >> 4) & 0x0F);

                        result[0] = toHexChar(firstHalf);
                        result[1] = toHexChar(secondHalf);

                        break :hexString result;
                    };
                    
                    raylib.DrawTextEx(
                        fontTtf,
                        &hexString,
                        pos,
                        fontSize,
                        textSpacing,
                        raylib.WHITE);

                    colIndex += 1;
                    if (colIndex == rangeSize.cols)
                    {
                        colIndex = 0;
                        lineIndex += 1;
                    }
                }

                if (!iter.advance())
                {
                    break;
                }
            }
        }

    }
}

test
{ 
    _ = pipelines;
    _ = parser.zlib;
    _ = parser.png;
}

