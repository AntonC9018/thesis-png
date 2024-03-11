const std = @import("std");
const parser = @import("parser.zig");
const pipelines = @import("pipelines.zig");

const raylib = @import("raylib");

const resourcesDir = "raylib/raylib/examples/text/resources/";

// 1. Transform parser results into tree
// 2. Draw bytes on screen
// 3. Draw image
// 4. Visualize the tree
// 5. Allow switching pages changing the current range
// 6. Deleting invisible parts of the tree
//

pub fn createFonts(fontSize: i32)
    !struct
    {
        sdf: raylib.Font,
        default: raylib.Font,
    }
{
    // Loading file to memory
    const fileData = try raylib.LoadFileData(resourcesDir ++ "anonymous_pro_bold.ttf");
    defer raylib.UnloadFileData(fileData);      

    const rectangles: ?[*]raylib.Rectangle = null;

    const glyphCount = 95;
    const default = default:
    {
        // Loading font data from memory data
        // Parameters > font size: 16, no glyphs array provided (0), glyphs count: 95 (autogenerate chars array)
        const glyphs = raylib.LoadFontData(
            @ptrCast(fileData),
            @intCast(fileData.len),
            fontSize,
            null,
            glyphCount,
            .FONT_DEFAULT);
        // Parameters > glyphs count: 95, font size: 16, glyphs padding in image: 4 px, pack method: 0 (default)
        const glyphPaddingInImage = 4;
        const packMethod = 0;
        var recs = rectangles;
        const atlas: raylib.Image = raylib.GenImageFontAtlas(
            glyphs,
            @ptrCast(&recs),
            glyphCount,
            fontSize,
            glyphPaddingInImage,
            packMethod);

        const texture = raylib.LoadTextureFromImage(atlas);
        raylib.UnloadImage(atlas);

        break :default raylib.Font
        {
            .glyphPadding = 0,
            .glyphCount = glyphCount,
            .texture = texture,
            .baseSize = fontSize,
            .recs = recs,
            .glyphs = glyphs,
        };
    };

    const sdf = sdf:
    {
        // Parameters > font size: 16, no glyphs array provided (0), glyphs count: 0 (defaults to 95)
        const glyphs = raylib.LoadFontData(
            @ptrCast(fileData),
            @intCast(fileData.len),
            fontSize,
            null,
            0,
            .FONT_SDF);
        // Parameters > glyphs count: 95, font size: 16, glyphs padding in image: 0 px, pack method: 1 (Skyline algorythm)
        const packMethod = 1; // Skiline algorithm
        var recs = rectangles;
        const atlas = raylib.GenImageFontAtlas(
            glyphs,
            @ptrCast(&recs),
            glyphCount,
            fontSize,
            0,
            packMethod);
        const texture = raylib.LoadTextureFromImage(atlas);
        raylib.UnloadImage(atlas);
        break :sdf raylib.Font
        {
            .baseSize = fontSize,
            .glyphCount = glyphCount,
            .glyphs = glyphs,
            .recs = recs,
            .texture = texture,
            .glyphPadding = 0,
        };
    };
    return .{
        .default = default,
        .sdf = sdf,
    };
}

pub fn main() !void
{
    const screenWidth = 800;
    const screenHeight = 450;
    const allocator = std.heap.page_allocator;

    raylib.InitWindow(screenWidth, screenHeight, "raylib [text] example - SDF fonts");

    // NOTE: Textures/Fonts MUST be loaded after Window initialization (OpenGL context is required)
    var fontSize: f32 = 16;
    const fonts = try createFonts(@intFromFloat(fontSize));
    defer 
    {
        raylib.UnloadFont(fonts.default);
        raylib.UnloadFont(fonts.sdf);
    }

    const shader = shader:
    {
        // Load SDF required shader (we use default vertex shader)
        const fragShaderName = try std.fmt.allocPrintZ(allocator, resourcesDir ++ "/shaders/glsl{d}/sdf.fs", .{ raylib.rlGetVersion() });
        defer allocator.free(fragShaderName);
        const s = raylib.LoadShader(null, fragShaderName);
        break :shader s;
    };
    defer raylib.UnloadShader(shader);
    raylib.SetTextureFilter(fonts.sdf.texture, .TEXTURE_FILTER_BILINEAR);
    raylib.SetTargetFPS(60);

    while (!raylib.WindowShouldClose())
    {
        fontSize += raylib.GetMouseWheelMove() * 8.0;

        if (fontSize < 6)
        {
            fontSize = 6;
        }

        const currentFont: enum { Default, SDF } = c:
        {
            if (raylib.IsKeyDown(.KEY_SPACE))
            {
                break :c .SDF;
            }
            else
            {
                break :c .Default;
            }
        };

        const font = switch (currentFont)
        {
            .Default => fonts.default,
            .SDF => fonts.sdf,
        };
        const message = "Signed Distance Fields";
        const textSize = raylib.MeasureTextEx(font, message, fontSize, 0);
        const textPosition = textPosition:
        {
            const h: f32 = @floatFromInt(raylib.GetScreenHeight());
            const w: f32 = @floatFromInt(raylib.GetScreenWidth());
            break :textPosition .{
                .x = w / 2 - textSize.x / 2,
                .y = h / 2 - textSize.y / 2 + 80,
            };
        };

        {
            raylib.BeginDrawing();
            defer raylib.EndDrawing();

            raylib.ClearBackground(raylib.RAYWHITE);

            switch (currentFont)
            {
                .Default =>
                {
                    raylib.DrawTextEx(font, message, textPosition, fontSize, 0, raylib.BLACK);
                },
                .SDF =>
                {
                    raylib.BeginShaderMode(shader);
                    defer raylib.EndShaderMode();
                    raylib.DrawTextEx(font, message, textPosition, fontSize, 0, raylib.BLACK);
                },
            }

            raylib.DrawTexture(font.texture, 10, 10, raylib.BLACK);

            switch (currentFont)
            {
                .Default => raylib.DrawText("Default", 315, 40, 30, raylib.GRAY),
                .SDF => raylib.DrawText("SDF!", 320, 20, 80, raylib.RED),
            }

            const renderSizeText = try std.fmt.allocPrintZ(allocator, "RENDER SIZE: {d:2.2}", .{ fontSize });
            defer allocator.free(renderSizeText);

            raylib.DrawText("FONT SIZE: 16.0", raylib.GetScreenWidth() - 240, 20, 20, raylib.DARKGRAY);
            raylib.DrawText(renderSizeText, raylib.GetScreenWidth() - 240, 50, 20, raylib.DARKGRAY);
            raylib.DrawText("Use MOUSE WHEEL to SCALE TEXT!", raylib.GetScreenWidth() - 240, 90, 10, raylib.DARKGRAY);

            raylib.DrawText("HOLD SPACE to USE SDF FONT VERSION!", 340, raylib.GetScreenHeight() - 30, 20, raylib.MAROON);

        }
    }

    raylib.CloseWindow();
}

test
{ 
    _ = pipelines;
    _ = @import("zlib/zlib.zig");
}

