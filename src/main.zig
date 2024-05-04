const std = @import("std");
const parser = @import("parser/module.zig");
const png = parser.png;

const debug = @import("pngDebug.zig");
const ast = @import("ast.zig");

fn parseIntoTree(allocator: std.mem.Allocator) !ast.AST
{
    var testContext = try debug.openTestReader(allocator);
    defer testContext.deinit();

    const reader = &testContext.reader;
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

    return tree;
}

const raylib = @import("raylib");

pub fn main() !void
{
    const allocator = std.heap.page_allocator;
    var tree = try parseIntoTree(allocator);

    var currentPosition: raylib.Vector2 = .{ .x = 10, .y = 30 + 10 };

    raylib.SetConfigFlags(.{ .FLAG_WINDOW_RESIZABLE = true });
    raylib.InitWindow(1200, 1200, "hello world!");
    raylib.SetTargetFPS(60);

    defer raylib.CloseWindow();

    const fontSize = 20;
    const lineHeight = 30;
    const fontTtf = raylib.LoadFontEx("resources/monofonto.otf", fontSize, null, 250);

    while (!raylib.WindowShouldClose())
    {
        raylib.BeginDrawing();
        defer raylib.EndDrawing();
        
        raylib.ClearBackground(raylib.BLACK);
        // raylib.DrawFPS(10, 10);

        {
            const scrollSpeed: f32 = 40;
            currentPosition.y += raylib.GetMouseWheelMove() * scrollSpeed;
        }
        {
            const moveSpeed: f32 = 20;
            const helper = .{
                .{
                    .key = .KEY_LEFT,
                    .value = .{ .x = 1, .y = 0 },
                },
                .{
                    .key = .KEY_RIGHT,
                    .value = .{ .x = -1, .y = 0 },
                },
                .{
                    .key = .KEY_UP,
                    .value = .{ .x = 0, .y = 1 },
                },
                .{
                    .key = .KEY_DOWN,
                    .value = .{ .x = 0, .y = -1 },
                },
            };
            inline for (helper) |h|
            {
                if (raylib.IsKeyDown(h.key))
                {
                    const vector: raylib.Vector2 = h.value;
                    const translation = vector.scale(moveSpeed);
                    currentPosition = currentPosition.add(translation);
                }
            }
        }

        const Context = struct
        {
            currentPosition: raylib.Vector2,
            tree: *ast.AST,
            allocator: std.mem.Allocator,
            font: raylib.Font,

            fn drawTextLine(context: *@This(), string: [:0]const u8) void
            {
                const spacing = 2;
                raylib.DrawTextEx(
                    context.font,
                    string,
                    context.currentPosition,
                    fontSize,
                    spacing,
                    raylib.WHITE);
                context.currentPosition.y += lineHeight;
            }
        };
        var context = Context
        {
            .currentPosition = currentPosition,
            .tree = &tree,
            .allocator = allocator,
            .font = fontTtf,
        };

        const draw = struct
        {
            fn f(nodeIndex: usize, context_: *Context) !void
            {
                const node: *ast.Node = &context_.tree.syntaxNodes.items[nodeIndex];

                var writerBuf = std.ArrayList(u8).init(context_.allocator);
                defer writerBuf.clearAndFree();
                const writer = writerBuf.writer();

                {
                    const start = node.span.start;
                    const end = node.span.endInclusive;
                    try writer.print(
                        "Range[{d},{d}:{d},{d}]",
                        .{
                            start.byte,
                            start.bit,
                            end.byte,
                            end.bit,
                        });
                }

                if (node.data != ast.invalidDataIndex)
                {
                    const printString = struct
                    {
                        fn f(writer_: anytype, string: []const u8) !void
                        {
                            for (string) |ch|
                            {

                                const specialCh = switch (ch)
                                {
                                    '\n' => "\\n",
                                    '\r' => "\\r",
                                    0 => "\\0",
                                    else => null,
                                };
                                if (specialCh) |special|
                                {
                                    _ = try writer_.print("{s}", .{ special });
                                }
                                else
                                {
                                    _ = try writer_.print("{}", .{ ch });
                                }
                            }
                        }

                    }.f;
                    const data = context_.tree.nodeDatas.items[node.data];
                    try writer.print(", Value: ", .{});
                    switch (data)
                    {
                        .LiteralString => |s|
                        {
                            try printString(writer, s);
                        },
                        .OwnedString => |s|
                        {
                            try printString(writer, s.items);
                        },
                        .ChunkType => |t|
                        {
                            try printString(writer, &t.getString());
                        },
                        inline else => |d| try writer.print("{}", .{ d }),
                    }
                }
                if (node.nodeType != .Container)
                {
                    try writer.print(", Type: ", .{});
                    switch (node.nodeType)
                    {
                        inline else => |t| try writer.print("{}", .{ t }),
                    }
                }
                try writer.writeByte(0);

                context_.drawTextLine(writerBuf.items[0 .. writerBuf.items.len - 1: 0]);

                if (node.syntaxChildren.len() > 0)
                {
                    const offsetSize = 20;
                    context_.currentPosition.x += offsetSize;
                    defer context_.currentPosition.x -= offsetSize;

                    for (node.syntaxChildren.array.items) |childNodeIndex|
                    {
                        try f(childNodeIndex, context_);
                    }
                }
           }
        }.f;

        for (tree.rootNodes.items) |rootNodeIndex|
        {
            try draw(rootNodeIndex, &context);
        }
    }
}

test
{ 
    const pipelines = parser.pipelines;
    _ = pipelines;
    _ = parser.zlib;
    _ = parser.png;
}

