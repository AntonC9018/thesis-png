const std = @import("std");
const parser = @import("parser/module.zig");
const png = parser.png;

const debug = @import("pngDebug.zig");
const ast = @import("ast.zig");

const pipelines = parser.pipelines;
const ByteRange = pipelines.ByteRange;

const TreeContext = struct
{
    bufferManager: pipelines.BufferManager,
    tree: ast.AST,

    pub fn deinit(self: *TreeContext, allocator: std.mem.Allocator) void
    {
        self.bufferManager.deinit(allocator);
        self.tree.deinit(allocator);
    }
};

fn parseIntoTree(allocator: std.mem.Allocator, filePath: []const u8) !TreeContext
{
    var testContext = try debug.openTestReader(allocator, filePath);
    defer testContext.deinit();

    const reader = &testContext.reader;

    // We want to keep the whole file in memory for the operations after.
    // It's not optimal, we'd want to load parts of the file out of memory.
    // Maybe do that later?
    reader.buffer().lowerLimitHint = 0;

    var parserState = png.createParserState();
    const parserSettings = png.Settings
    {
        .logChunkStart = false,
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
                    std.debug.print("Non recoverable error {}\n", .{ err });
                    // break :outerLoop;
                    return err;
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

    pub fn byteOffsetFromCoord(
        self: RangeSize,
        coord: raylib.Vector2i) usize
    {
        return @as(usize, @intCast(coord.y)) * self.cols + @as(usize, @intCast(coord.x));
    }
};

fn componentwiseMult(v1: raylib.Vector2, v2: raylib.Vector2) raylib.Vector2
{
    return .{
        .x = v1.x * v2.x,
        .y = v1.y * v2.y,
    };
}

fn rectFromTopLeftAndSize(topLeft: raylib.Vector2, size: raylib.Vector2) raylib.Rectangle
{
    return .{
        .x = topLeft.x,
        .y = topLeft.y,
        .width = size.x,
        .height = size.y,
    };
}

fn integerRectFromTopLeftAndBottomRight(topLeft: raylib.Vector2i, bottomRight: raylib.Vector2i) raylib.RectangleI
{
    return .{
        .x = topLeft.x,
        .y = topLeft.y,
        .width = bottomRight.x - topLeft.x + 1,
        .height = bottomRight.y - topLeft.y + 1,
    };
}

fn addPaddingToRect(rect: raylib.Rectangle, padding: raylib.Vector2) raylib.Rectangle
{
    return .{
        .x = rect.x - padding.x,
        .y = rect.y - padding.y,
        .width = rect.width + padding.x * 2,
        .height = rect.height + padding.y * 2,
    };
}

fn rectContainsPoint(rect: raylib.Rectangle, point: raylib.Vector2) bool
{
    return point.x >= rect.x and point.x <= rect.x + rect.width and
           point.y >= rect.y and point.y <= rect.y + rect.height;
}

// Segment TreeSearch begin 
fn updateNodePathForPosition(
    tree: *const ast.AST,
    bytePosition: usize,
    nodePath: *std.ArrayList(ast.NodeIndex)) !void
{
    const nodePosition = parser.ast.Position
    {
        .byte = bytePosition,
        .bit = 0,
    };

    nodePath.clearRetainingCapacity();
    const rootNodeIndex = rootNode:
    {
        // Could do binary search, but there's not going to be much benefit.
        for (tree.rootNodes.items) |rootIndex|
        {
            const node = &tree.syntaxNodes.items[rootIndex];
            if (node.span.includesPosition(nodePosition))
            {
                break :rootNode rootIndex;
            }
        }
        return;
    };

    var currentIndex: usize = 0;
    try nodePath.append(rootNodeIndex);
    while (currentIndex < nodePath.items.len)
    {
        const nodeIndex = nodePath.items[currentIndex];
        const node = &tree.syntaxNodes.items[nodeIndex];

        // It doesn't really matter if it's a BFS or a DFS.
        // For a DFS the logic is somewhat more complicated / use recursion.
        currentIndex += 1;

        for (node.syntaxChildren.array.items) |childIndex|
        {
            const child = &tree.syntaxNodes.items[childIndex];
            if (child.span.includesPosition(nodePosition))
            {
                try nodePath.append(childIndex);
            }
        }
    }
}
// Segment TreeSearch end 

const TextSizes = struct
{
    spacing: f32,
    columnSpacing: f32,
    fontSize: f32,
    byte: raylib.Vector2,
    byteSpacing: raylib.Vector2,
    bytePadded: raylib.Vector2,

    const Self = @This();

    fn getBytePositionFromCoord(self: Self, pos: raylib.Vector2i) raylib.Vector2
    {
        const textPos = componentwiseMult(pos.float(), self.bytePadded);
        return textPos;
    }

    fn getByteBox(self: Self, pos: raylib.Vector2i) raylib.Rectangle
    {
        const textPos = self.getBytePositionFromCoord(pos);
        const textRect = rectFromTopLeftAndSize(textPos, self.byte);
        const paddedRect = addPaddingToRect(textRect, .{
            .x = self.columnSpacing / 2,
            .y = 0,
        });
        return paddedRect;
    }

    fn getMultibyteBox(self: Self, rect: raylib.RectangleI) raylib.Rectangle
    {
        const topLeftCoord = .{
            .x = rect.x,
            .y = rect.y,
        };
        const topLeft = self.getBytePositionFromCoord(topLeftCoord);

        const bottomRightCoord = .{
            .x = rect.x + rect.width - 1,
            .y = rect.y + rect.height - 1,
        };
        const bottomRightTopLeft = self.getBytePositionFromCoord(bottomRightCoord);

        const bottomRightBottomRight = bottomRightTopLeft.add(self.byte);

        return addPaddingToRect(raylib.Rectangle
            {
                .x = topLeft.x,
                .y = topLeft.y,
                .width = bottomRightBottomRight.x - topLeft.x,
                .height = bottomRightBottomRight.y - topLeft.y,
            }, .{
                .x = self.columnSpacing / 2,
                .y = 0,
            });
    }
};

const raylib = @import("raylib");

const DrawMultilineTextArgs = struct
{
    font: raylib.Font,
    buffer: *std.ArrayList(u8),
    textSizes: TextSizes,
    position: *raylib.Vector2,
    color: raylib.Color,
};

fn drawTextMultiline(p: DrawMultilineTextArgs) !void
{
    if (p.buffer.items.len == 0)
    {
        return error.NothingToDraw;
    }
    try p.buffer.append(0);

    var start: usize = 0;
    var end: usize = 0;
    while (end < p.buffer.items.len)
    {
        const ch = &p.buffer.items[end];

        if (ch.* == '\n')
        {
            ch.* = 0;
        }
        if (ch.* == 0)
        {
            const slice = p.buffer.items[start .. end : 0];

            raylib.DrawTextEx(
                p.font,
                slice,
                p.position.*,
                p.textSizes.fontSize,
                p.textSizes.spacing,
                p.color); 

            p.position.y += p.textSizes.bytePadded.y;
            end += 1;
            start = end;
        }
        end += 1;
    }
}

const UiState = struct
{
    rangeSize: RangeSize = .{
        .rows = 16,
        .cols = 16,
    },
    rangeIndex: usize = 0,
    clickedPosition: ?raylib.Vector2i = null,
    displayingPosition: ?raylib.Vector2i = null,
    currentNodePath: std.ArrayList(ast.NodeIndex),

    fn deinit(self: *UiState) void
    {
        self.currentNodePath.deinit();
    }

    fn treeReset(self: *UiState) void
    {
        self.rangeIndex = 0;
        self.rangeReset();
    }

    fn rangeReset(self: *UiState) void
    {
        self.clickedPosition = null;
        self.displayingPosition = null;
        self.currentNodePath.clearRetainingCapacity();
    }
};

// Segment HexGrid begin
fn drawHexBytes(
    p: struct
    {
        sequence: pipelines.Sequence,
        textSizes: TextSizes,
        font: raylib.Font,
        rangeSize: RangeSize,
    }) !void
{
    var gridCoord = raylib.Vector2i
    {
        .x = 0,
        .y = 0,
    };

    var iter = p.sequence.iterate() orelse return;
    while (true)
    {
        const bytes = iter.current();

        for (bytes) |b|
        {
            const cellPos = gridCoord.float();
            const pos = componentwiseMult(cellPos, p.textSizes.bytePadded);

            const hexString = hexString: {
                var result: [2:0]u8 = undefined;
                result[2] = 0;

                const firstHalf: u4 = @intCast(b & 0x0F);
                const secondHalf: u4 = @intCast((b >> 4) & 0x0F);

                result[0] = toHexChar(secondHalf);
                result[1] = toHexChar(firstHalf);

                break :hexString result;
            };

            raylib.DrawTextEx(
                p.font,
                &hexString,
                pos,
                p.textSizes.fontSize,
                p.textSizes.spacing,
                raylib.WHITE);

            gridCoord.x += 1;
            if (gridCoord.x == p.rangeSize.cols)
            {
                gridCoord.x = 0;
                gridCoord.y += 1;
            }
        }

        if (!iter.advance())
        {
            break;
        }
    }
}
// Segment HexGrid end

pub fn main() !void
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var tempBuffer = std.ArrayList(u8).init(allocator);
    errdefer tempBuffer.deinit();

    try tempBuffer.ensureTotalCapacity(std.fs.MAX_PATH_BYTES);

    var treeContext = treeContext:
    {
        const cwd = std.fs.cwd();

        defer tempBuffer.clearRetainingCapacity();

        const relativePath = "test_data/parot_chromaticities.png";
        tempBuffer.items = try cwd.realpath(relativePath, tempBuffer.items.ptr[0 .. tempBuffer.capacity]);

        const t = try parseIntoTree(allocator, tempBuffer.items);
        break :treeContext t;
    };

    var ui = ui:
    {
        var currentNodePath = std.ArrayList(ast.NodeIndex).init(allocator);
        errdefer currentNodePath.deinit();
        break :ui UiState 
        {
            .currentNodePath = currentNodePath,
        };
    };
    defer ui.deinit();

    raylib.SetConfigFlags(.{ .FLAG_WINDOW_RESIZABLE = true });
    raylib.InitWindow(1000, 600, "PNG exploration");
    raylib.SetTargetFPS(60);

    defer raylib.CloseWindow();

    const fontSize = 32;
    const fontTtf = raylib.LoadFontEx("resources/monofonto.otf", fontSize, null, 250);

    while (!raylib.WindowShouldClose())
    {
        raylib.BeginDrawing();
        defer raylib.EndDrawing();
        
        raylib.ClearBackground(raylib.BLACK);

        // Segment DragAndDrop begin
        if (raylib.IsFileDropped()) file:
        {
            const filePaths = raylib.LoadDroppedFiles();
            defer raylib.UnloadDroppedFiles(filePaths);

            const firstFile = filePaths.paths[0];
            const firstFileSlice = std.mem.sliceTo(firstFile, 0);

            const newTreeContext = parseIntoTree(allocator, firstFileSlice) catch
            {
                // Might want to do better error cathing here.
                break :file;
            };

            treeContext.deinit(allocator);
            treeContext = newTreeContext;
            ui.treeReset();
        }
        // Segment DragAndDrop end

        {
            const newIndex = newIndex:
            {
                if (raylib.IsKeyPressed(.KEY_EQUAL))
                {
                    break :newIndex @min(ui.rangeIndex + 1, ui.rangeSize.getRangeCount(treeContext.bufferManager.totalBytes));
                }
                if (raylib.IsKeyPressed(.KEY_MINUS))
                {
                    break :newIndex ui.rangeIndex -| 1;
                }
                break :newIndex ui.rangeIndex;
            };
            if (newIndex != ui.rangeIndex)
            {
                ui.rangeIndex = newIndex;
                ui.rangeReset();
            }
        }

        const range = ui.rangeSize.computeRange(ui.rangeIndex);
        const sequence = treeContext.bufferManager.getSegmentForRange(range);

        const textSizes = textSizes:
        {
            const textSpacing = 0;
            const columnSpacing = 10;
            const byteTextSize = raylib.MeasureTextEx(fontTtf, "00", fontSize, textSpacing);
            const byteSpacing = raylib.Vector2
            {
                .x = textSpacing + columnSpacing,
                .y = textSpacing,
            };
            const byteTextSizePadded = byteTextSize.add(byteSpacing);
            
            break :textSizes TextSizes
            {
                .fontSize = fontSize,
                .byte = byteTextSize,
                .byteSpacing = byteSpacing,
                .bytePadded = byteTextSizePadded,
                .spacing = textSpacing,
                .columnSpacing = columnSpacing,
            };
        };

        const allTextRect = allTextRect:
        {
            const rangeSizeAsVec = (raylib.Vector2i
                {
                    .x = @intCast(ui.rangeSize.cols),
                    .y = @intCast(ui.rangeSize.rows),
                }).float();
            break :allTextRect rectFromTopLeftAndSize(
                raylib.Vector2.zero(),
                componentwiseMult(rangeSizeAsVec, textSizes.bytePadded));
        };

        {
            defer tempBuffer.clearRetainingCapacity();

            {
                const writer = tempBuffer.writer();
                try writer.print("{d}/{d}", .{
                    ui.rangeIndex + 1,
                    ui.rangeSize.getRangeCount(treeContext.bufferManager.totalBytes) + 1,
                });
                try writer.writeByte(0);
            }
            const str = tempBuffer.items[0 .. tempBuffer.items.len - 1 : 0];
            const size = raylib.MeasureTextEx(
                fontTtf,
                str,
                textSizes.fontSize,
                textSizes.spacing);
            raylib.DrawTextEx(
                fontTtf,
                str,
                allTextRect.bottomCenter().add(.{
                    .x = -size.x * 0.5,
                    .y = 0,
                }),
                fontSize,
                textSizes.spacing,
                raylib.WHITE);
        }

        const newDisplayPosition = squareSelection:
        {
            const mousePos = raylib.GetMousePosition();

            if (!rectContainsPoint(allTextRect, mousePos))
            {
                break :squareSelection null;
            }
            const relativePos = mousePos.sub(allTextRect.topLeft());
            const gridCoord = raylib.Vector2i
            {
                .x = @intFromFloat(@floor(relativePos.x / textSizes.bytePadded.x)),
                .y = @intFromFloat(@floor(relativePos.y / textSizes.bytePadded.y)),
            };

            const byteOffset = ui.rangeSize.byteOffsetFromCoord(gridCoord);

            if (byteOffset >= sequence.len())
            {
                break :squareSelection null;
            }

            if (raylib.IsMouseButtonReleased(.MOUSE_BUTTON_LEFT))
            {
                ui.clickedPosition = gridCoord;
            }
            break :squareSelection gridCoord;
        } orelse ui.clickedPosition;

        if (!std.meta.eql(ui.displayingPosition, newDisplayPosition))
        {
            ui.displayingPosition = newDisplayPosition;
            if (ui.displayingPosition) |p|
            {
                const byteOffset = ui.rangeSize.byteOffsetFromCoord(p);
                const bytePosition = ui.rangeSize.byteCount() * ui.rangeIndex + byteOffset;
                try updateNodePathForPosition(&treeContext.tree, bytePosition, &ui.currentNodePath);
            }
            else
            {
                ui.currentNodePath.clearRetainingCapacity();
            }
        }

        if (ui.currentNodePath.items.len > 0) highlightOfRange:
        {
            const n = ui.currentNodePath.items;
            const lastNodeIndex = n[n.len - 1];
            const lastNode = &treeContext.tree.syntaxNodes.items[lastNodeIndex];

            const startByteOffset = start:
            {
                const start = lastNode.span.start;
                if (start.byte < range.start)
                {
                    break :start 0;
                }

                const offset = start.byte - range.start;
                break :start offset;
            };

            const endByteOffset = end:
            {
                const end = lastNode.span.endExclusive;
                if (end.byte <= range.end)
                {
                    break :end end.byte - range.start;
                }
                break :end range.end;
            };
            if (endByteOffset == startByteOffset)
            {
                break :highlightOfRange;
            }
            const endByteOffsetInclusive = endByteOffset - 1;

            const startRow = startByteOffset / ui.rangeSize.cols;
            const endRow = endByteOffsetInclusive / ui.rangeSize.cols;
            const startCol = startByteOffset % ui.rangeSize.cols;
            const endCol = endByteOffsetInclusive % ui.rangeSize.cols;

            const highlightColor = .{ .r = 130, .g = 70, .b = 0, .a = 255 };

            const drawBox = struct
            {
                fn f(textSizes_: @TypeOf(textSizes), start: raylib.Vector2i, end: raylib.Vector2i) void
                {
                    const intRect = integerRectFromTopLeftAndBottomRight(start, end);
                    const floatRect = textSizes_.getMultibyteBox(intRect);
                    raylib.DrawRectangleRec(floatRect, highlightColor);
                }
            }.f;
            if (startRow != endRow)
            {
                {
                    const start = raylib.Vector2i
                    {
                        .x = @intCast(startCol),
                        .y = @intCast(startRow),
                    };
                    const end = raylib.Vector2i
                    {
                        .x = @intCast(ui.rangeSize.cols - 1),
                        .y = @intCast(startRow),
                    };
                    drawBox(textSizes, start, end);
                }
                if (endRow - startRow >= 2)
                {
                    const start = raylib.Vector2i
                    {
                        .x = 0,
                        .y = @intCast(startRow + 1),
                    };
                    const end = raylib.Vector2i
                    {
                        .x = @intCast(endCol),
                        .y = @intCast(endRow - 1),
                    };
                    drawBox(textSizes, start, end);
                }
                {
                    const start = raylib.Vector2i
                    {
                        .x = 0,
                        .y = @intCast(endRow),
                    };
                    const end = raylib.Vector2i
                    {
                        .x = @intCast(endCol),
                        .y = @intCast(endRow),
                    };
                    drawBox(textSizes, start, end);
                }
            }
            else
            {
                // a single segment
                const start = raylib.Vector2i
                {
                    .x = @intCast(startCol),
                    .y = @intCast(startRow),
                };
                const end = raylib.Vector2i
                {
                    .x = @intCast(endCol),
                    .y = @intCast(endRow),
                };
                drawBox(textSizes, start, end);
            }
        }

        if (ui.displayingPosition) |gridCoord|
        {
            const paddedRect = textSizes.getByteBox(gridCoord);
            raylib.DrawRectangleRec(paddedRect, raylib.GRAY);
        }
        if (ui.clickedPosition) |clickedPosition_|
        {
            const paddedRect = textSizes.getByteBox(clickedPosition_);
            raylib.DrawRectangleRec(paddedRect, raylib.BLUE);
        }

        // Draw the hex bytes.
        try drawHexBytes(.{
            .font = fontTtf,
            .rangeSize = ui.rangeSize,
            .sequence = sequence,
            .textSizes = textSizes,
        });

        // Draw the node info.
        {
            const nodeInfoBox = box:
            {
                const topLeftPosition = raylib.Vector2
                {
                    .x = allTextRect.width + 10,
                    .y = 0,
                };
                const width = @as(f32, @floatFromInt(raylib.GetScreenWidth())) - topLeftPosition.x;
                break :box rectFromTopLeftAndSize(topLeftPosition, .{
                    .x = width,
                    .y = @floatFromInt(raylib.GetScreenHeight()),
                });
            };

            raylib.DrawRectangleRec(nodeInfoBox, raylib.LIGHTGRAY);

            var currentPos = nodeInfoBox.topLeft();

            for (0 .., ui.currentNodePath.items) |nodeIndexIndex, nodeIndex|
            {
                const node = &treeContext.tree.syntaxNodes.items[nodeIndex];
                const data: ?ast.NodeData = if (ast.isDataIdInvalid(node.data))
                        null
                    else
                        treeContext.tree.nodeDatas.get(node.data);

                const writer = tempBuffer.writer();

                var drawMultilineTextArgs = DrawMultilineTextArgs
                {
                    .font = fontTtf,
                    .buffer = &tempBuffer,
                    .textSizes = textSizes,
                    .position = &currentPos,
                    .color = raylib.BLACK,
                };

                // Print the name based on the node type
                {
                    defer tempBuffer.clearRetainingCapacity();
                    switch (node.nodeType)
                    {
                        // action states
                        inline
                        .TopLevel,
                        .Chunk,
                        .ImageHeader,
                        .ICCProfile,
                        .TextAction,
                        .CompressedText,
                        .PhysicalPixelDimensions,
                        .Zlib,
                        .Deflate,
                        .NoCompression,
                        .SymbolDecompression,
                        .RGBComponent => |v|
                        {
                            const actionName = @tagName(v);
                            try writer.print("{s}", .{ actionName });
                        },
                        // void states
                        inline
                        .RGBColor,
                        .RenderingIntent,
                        .DeflateCode,
                        .ZlibContainer,
                        .ZlibSymbol,
                        .Container => |_, tag|
                        {
                            const tagName = @tagName(tag);
                            try writer.print("{s}", .{ tagName });
                        },
                        .DynamicHuffman => |v|
                        {
                            switch (v)
                            {
                                inline .CodeDecoding, .CodeFrequency => |action|
                                {
                                    const actionName = @tagName(action);
                                    try writer.print("{s}", .{ actionName });
                                },
                                .EncodedFrequency =>
                                {
                                    try writer.print("EncodedFrequency", .{});
                                },
                            }
                        },
                        .PrimaryChrom => |v|
                        {
                            try writer.print("Primary Chromaticities, vector {}, coord {}",
                                .{ v.vector(), v.coord() });
                        },
                    }

                    raylib.DrawLineV(currentPos, currentPos.add(.{
                        .x = nodeInfoBox.width,
                        .y = 0,
                    }), raylib.WHITE);
                    
                    drawMultilineTextArgs.color = .{
                        .r = 20,
                        .g = 100,
                        .b = 20,
                        .a = 255,
                    };
                    try drawTextMultiline(drawMultilineTextArgs);
                }

                const itemPadding = 20;

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
                                _ = try writer_.print("{c}", .{ ch });
                            }
                        }
                    }

                }.f;

                // Write the data.
                if (data) |data_| writeData:
                {
                    defer tempBuffer.clearRetainingCapacity();
                    switch (data_)
                    {
                        .LiteralString => |s|
                        {
                            try printString(writer, s);
                        },
                        .OwnedString => |s|
                        {
                            try printString(writer, s.items);
                        },
                        inline
                        .Number,
                        .U32,
                        .FilterMethod,
                        .CompressionMethod
                            => |n|
                        {
                            if (node.nodeType != .RGBComponent)
                            {
                                try writer.print("{d}", .{ n });
                            }
                        },
                        .Bool => |b|
                        {
                            try writer.print("{s}", .{ if (b) "Yes" else "No" });
                        },
                        .ChunkType => |t|
                        {
                            try writer.print("{s}", .{ t.getString() });
                        },
                        .ColorType => |ct|
                        {
                            try writer.print("Palette? {}\n", .{ ct.palleteUsed() });
                            try writer.print("Color? {}\n", .{ ct.colorUsed() });
                            try writer.print("Alpha? {}\n", .{ ct.alphaChannelUsed() });
                            try writer.print("Value: {}\n", .{ ct.flags });
                        },

                        inline
                        .InterlaceMethod,
                        .RenderingIntent,
                        .PixelUnitSpecifier,
                        .BlockType => |e|
                        {
                            try writer.print("{s}", .{ @tagName(e) });
                        },

                        .RGB, .RGB16 =>
                        {
                            // we don't write anything here, it's special.
                        },

                        .CompressionMethodAndFlags => |f|
                        {
                            try writer.print("Compression Info: {}\nCompression Method: {s}",
                                .{ f.compressionInfo, @tagName(f.compressionMethod) });
                        },
                        .ZlibFlags => |f|
                        {
                            try writer.print("Check: {}\nCompression Level: {s}\nPreset Dictionary: {}", .{
                                f.check,
                                @tagName(f.compressionLevel),
                                f.presetDictionary,
                            });
                        },
                        .ZlibSymbol => |s|
                        {
                            switch (s)
                            {
                                .EndBlock =>
                                {
                                    try writer.print("End of block", .{});
                                },
                                .LiteralValue => |lit|
                                {
                                    try writer.print("Literal {d}", .{ lit });
                                },
                                .BackReference => |bref|
                                {
                                    try writer.print("Buffer back-reference at distance {d} of length {d}", 
                                        .{ bref.distance, bref.len });
                                },
                            }
                        },
                    }

                    if (tempBuffer.items.len > 0)
                    {
                        drawMultilineTextArgs.color = raylib.BLACK;
                        try drawTextMultiline(drawMultilineTextArgs);
                        currentPos.y += itemPadding;
                        break :writeData;
                    }

                    // Display a swatch of that color.
                    const color = color:
                    {
                        switch (data_) 
                        {
                            inline .RGB, .RGB16 => |rgb|
                            {
                                break :color raylib.Color
                                {
                                    .a = 255,
                                    .r = @intCast(rgb.r),
                                    .g = @intCast(rgb.g),
                                    .b = @intCast(rgb.b),
                                };
                            },
                            inline .Number, .U32 => |rgbComponent|
                            {
                                std.debug.assert(nodeIndexIndex != 0);
                                std.debug.assert(node.nodeType == .RGBComponent);
                                const parentNodeIndex = ui.currentNodePath.items[nodeIndexIndex - 1];
                                const parentNode = &treeContext.tree.syntaxNodes.items[parentNodeIndex];
                                std.debug.assert(parentNode.nodeType == .RGBColor);
                                const indexOfSelfInParent = i:
                                {
                                    const children = parentNode.syntaxChildren.array.items;
                                    for (0 .., children) |i, childIndex|
                                    {
                                        if (childIndex == nodeIndex)
                                        {
                                            break :i i;
                                        }
                                    }
                                    unreachable;
                                };

                                const colorComponentIndex = indexOfSelfInParent;
                                var c = std.mem.zeroInit(raylib.Color, .{
                                    .a = 255,
                                });
                                const byteComponent: u8 = @intCast(rgbComponent);
                                switch (colorComponentIndex)
                                {
                                    0 => c.r = byteComponent,
                                    1 => c.g = byteComponent,
                                    2 => c.b = byteComponent,
                                    else => unreachable,
                                }
                                break :color c;
                            },
                            else => unreachable,
                        }
                    };

                    raylib.DrawRectangleRec(
                        rectFromTopLeftAndSize(currentPos, textSizes.byte),
                        color);
                    currentPos.y += textSizes.byte.y + itemPadding;

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

