const std = @import("std");
const parser = @import("parser.zig");
const pipelines = @import("pipelines.zig");

const raylib = @import("raylib");

pub fn main() !void
{
    // try @import("pngDebug.zig").readTestFile();

    raylib.SetConfigFlags(raylib.ConfigFlags{ .FLAG_WINDOW_RESIZABLE = true });
    raylib.InitWindow(800, 800, "hello world!");
    raylib.SetTargetFPS(60);

    defer raylib.CloseWindow();

    while (!raylib.WindowShouldClose())
    {
        raylib.BeginDrawing();
        defer raylib.EndDrawing();
        
        raylib.ClearBackground(raylib.BLACK);
        raylib.DrawFPS(10, 10);

        raylib.DrawText("hello world!", 100, 100, 20, raylib.YELLOW);
    }
}

test
{ 
    _ = pipelines;
    _ = @import("zlib/zlib.zig");
}

