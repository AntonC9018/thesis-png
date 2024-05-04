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

    outerLoop: while (true)
    {
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

            break;
        }

        try reader.advance(sequence.start());
    }

    return tree;
}

const raylib = @import("raylib");

pub fn main() !void
{
    const allocator = std.heap.page_allocator;
    var tree = try parseIntoTree(allocator);

    raylib.SetConfigFlags(.{ .FLAG_WINDOW_RESIZABLE = true });
    raylib.InitWindow(800, 800, "hello world!");
    raylib.SetTargetFPS(60);

    defer raylib.CloseWindow();

    while (!raylib.WindowShouldClose())
    {
        raylib.BeginDrawing();
        defer raylib.EndDrawing();
        
        raylib.ClearBackground(raylib.BLACK);
        raylib.DrawFPS(10, 10);

        const fontSize = 20;
        const lineHeight = 30;
        const Context = struct
        {
            currentPosition: raylib.Vector2i,
            tree: *ast.AST,
            allocator: std.mem.Allocator,

            fn drawTextLine(context: *@This(), s: [:0]const u8) void
            {
                const p = &context.currentPosition;
                raylib.DrawText(s, p.x, p.y, fontSize, raylib.WHITE);
                p.y += lineHeight;
            }
        };
        var context = Context
        {
            .currentPosition = .{ .x = 10, .y = 30 + 10 },
            .tree = &tree,
            .allocator = allocator,
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
                        "Node {d}, Range [{d},{d}:{d},{d}]",
                        .{
                            nodeIndex,
                            start.byte,
                            start.bit,
                            end.byte,
                            end.bit,
                        });
                }

                if (node.data != ast.invalidDataIndex)
                {
                    const data = context_.tree.nodeDatas.items[node.data];

                    try writer.print("Data: {}", .{ data });
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

