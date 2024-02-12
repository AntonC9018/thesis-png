const std = @import("std");
const p = @import("pipelines.zig");

// What is the next expected type?
pub const ParserAction = enum(u8) 
{
    Signature = 0,
    StartChunk,
    Chunk,
};

pub const ParserState = union(ParserAction)
{
    Signature: void,
    StartChunk: void,
    Chunk: ChunkParserState,
};

pub fn isParserStateTerminal(state: *const ParserState) bool 
{
    return state.* == .StartChunk;
}

pub const ParserContext = struct
{
    state: *ParserState,
    sequence: *p.Sequence,
    allocator: std.mem.Allocator,
    ihdr: ?IHDR,
};

pub const ChunkParserStateKey = enum 
{
    // Length of the data field.
    Length,
    ChunkType,
    Data,
    CyclicRedundancyCheck,
    Done,
};

pub const NodeBase = struct
{
    startPositionInFile: usize = 0,
    length: usize = 0,

    pub fn endPositionInFile(self: NodeBase) usize 
    {
        return self.startPositionInFile + self.length;
    }
};

pub const ChunkLengthNode = struct
{
    base: NodeBase,
    byteLength: u32,
};

pub const ChunkTypeNode = struct
{
    base: NodeBase,
    chunkType: ChunkType,
};

pub const ChunkDataNode = struct
{
    base: NodeBase,
    data: union
    { 
        ihdr: IHDR,
        plte: PLTE,
        none: void,
    },
};

pub const IHDR = struct
{
    width: u32,
    height: u32,
    bitDepth: BitDepth,
    colorType: ColorType,
    compressionMethod: CompressionMethod,
    filterMethod: FilterMethod,
    interlaceMethod: InterlaceMethod,
};

pub const RGB = struct
{
    r: u8,
    g: u8,
    b: u8,
};

pub const PLTE = struct
{
    colors: std.ArrayListUnmanaged(RGB),
};

pub const BitDepth = u8;

pub const ColorType = struct
{
    flags: u8,

    const PalleteUsed = 1 << 0;
    const ColorUsed = 1 << 1;
    const AlphaChannelUsed = 1 << 2;

    pub fn palleteUsed(self: ColorType) bool
    {
        return (self.flags & PalleteUsed) != 0;
    }
    pub fn colorUsed(self: ColorType) bool
    {
        return (self.flags & ColorUsed) != 0;
    }
    pub fn alphaChannelUsed(self: ColorType) bool
    {
        return (self.flags & AlphaChannelUsed) != 0;
    }
};

fn isBitDepthValid(bitDepth: BitDepth) bool
{
    return contains(&[_]u8{ 1, 2, 4, 8, 16 }, bitDepth);
}

fn isColorTypeValid(colorType: ColorType) bool
{
    return contains(&[_]u8{ 
        0,
        ColorType.ColorUsed,
        ColorType.ColorUsed | ColorType.PalleteUsed,
        ColorType.AlphaChannelUsed,
        ColorType.ColorUsed | ColorType.AlphaChannelUsed,
    }, colorType.flags);
}

fn isColorTypeAllowedForBitDepth(
    bitDepth: BitDepth,
    colorType: ColorType) bool
{
    const allowedValues = switch (colorType.flags)
    {
        // Each pixel is a grayscale sample.
        0 => &[_]u8{ 1, 2, 4, 8, 16 },

        // Each pixel is an R, G, B triple.
        ColorType.ColorUsed => &[_]u8{ 8, 16 },

        // Each pixel is a palette index; a PLTE chunk must appear.
        ColorType.ColorUsed | ColorType.PalleteUsed => &[_]u8{ 1, 2, 4, 8 },

        // Each pixel is a grayscale sample, followed by an alpha sample.
        ColorType.AlphaChannelUsed => &[_]u8{ 8, 16 },

        // Each pixel is an R, G, B triple, followed by an alpha sample.
        ColorType.ColorUsed | ColorType.AlphaChannelUsed => &[_]u8{ 8, 16 },

        else => return false,
    };
    return contains(allowedValues, bitDepth);
}

fn getSampleDepth(ihdr: IHDR) u8
{
    return switch (ihdr.colorType.flags)
    {
        ColorType.ColorUsed | ColorType.PalleteUsed => 8,
        else => ihdr.bitDepth,
    };
}

pub const CompressionMethod = u8;

fn isCompressionMethodValid(compressionMethod: CompressionMethod) bool
{
    return compressionMethod == 0;
}

pub const FilterMethod = u8;

fn isFilterMethodValid(filterMethod: FilterMethod) bool
{
    return filterMethod == 0;
}

pub const InterlaceMethod = enum(u8)
{
    None = 0,
    Adam7 = 1,
    _,
};

fn contains(arr: []const u8, value: u8) bool
{
    for (arr) |item|
    {
        if (item == value)
        {
            return true;
        }
    }
    return false;
}

pub const ChunkCyclicRedundancyCheckNode = struct
{
    base: NodeBase,
    crc: CyclicRedundancyCheck,
};

pub const CyclicRedundancyCheck = struct
{
    value: u32,
};

pub const ChunkNode = struct
{
    base: NodeBase,
    byteLength: u32,
    chunkType: ChunkType,
    dataNode: ChunkDataNode,
    crc: CyclicRedundancyCheck,
};

pub const SignatureNode = struct 
{
    base: NodeBase,
};

pub const TopLevelNode = union(enum) 
{
    signatureNode: SignatureNode,
    chunkNode: ChunkNode,

    pub fn base(self: TopLevelNode) NodeBase 
    {
        switch (self) 
        {
            inline else => |*n| return @as(*NodeBase, n), 
        }
    }
};

pub const ChunkParserState = struct
{
    key: ChunkParserStateKey = .Length,
    node: ChunkNode,
    dataNode: DataNodeParserState,
};

pub const DataNodeParserState = union
{
    ihdr: IHDRParserStateKey,
    bytesSkipped: u32,
    plte: PLTEState, 
    none: void,
};

pub const IHDRParserStateKey = enum(u32)
{
    const Initial = .Width;
    Width,
    Height,
    BitDepth,
    ColorType,
    CompressionMethod,
    FilterMethod,
    InterlaceMethod,
    Done,
};

pub const PLTEState = struct
{
    bytesRead: u32,
    rgb: RGBState,
};

pub const RGBState = enum
{
    None,
    R,
    G,
    B,

    const FirstColor = .R;

    fn next(self: RGBState) RGBState
    {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};

const pngFileSignature = "\x89PNG\r\n\x1A\n";
fn validateSignature(slice: *p.Sequence) !void 
{
    var copy = slice.*;
    p.removeFront(&copy, pngFileSignature)
    catch |err| switch (err)
    {
        error.NoMatch => return error.SignatureMismatch,
        else => return err,
    };
    slice.* = copy;
}

const ChunkTypeMetadataMask = struct 
{
    mask: ChunkType,
    
    pub fn ancillary() ChunkTypeMetadataMask 
    {
        var result: ChunkType = {};
        result.bytes[0] = 0x20;
        return result;
    }
    pub fn private() ChunkTypeMetadataMask 
    {
        var result: ChunkType = {};
        result.bytes[1] = 0x20;
        return result;
    }
    pub fn safeToCopy() ChunkTypeMetadataMask 
    {
        var result: ChunkType = {};
        result.bytes[3] = 0x20;
        return result;
    }

    pub fn check(self: ChunkTypeMetadataMask, chunkType: ChunkType) bool 
    {
        return (chunkType.value & self.mask.value) == self.mask.value;
    }
    pub fn set(self: ChunkTypeMetadataMask, chunkType: ChunkType) ChunkType 
    {
        return ChunkType { .value = chunkType.value | self.mask.value, };
    }
    pub fn unset(self: ChunkTypeMetadataMask, chunkType: ChunkType) ChunkType 
    {
        return ChunkType { .value = chunkType.value & (~self.mask.value), };
    }
};

pub const ChunkType = extern union 
{
    bytes: [4]u8,
    value: u32,
};

const KnownDataChunkTags = struct
{
    const IHDR = ChunkType { .bytes = "IHDR".* };
    const PLTE = ChunkType { .bytes = "PLTE".* };
};

pub fn printStepName(writer: anytype, parserState: *const ParserState) !void
{
    switch (parserState.*)
    {
        .Signature => try writer.print("Signature", .{}),
        .Chunk => |*chunk| 
        {
            try writer.print("Chunk ", .{});
            switch (chunk.key)
            {
                .Length => try writer.print("Length", .{}),
                .ChunkType => try writer.print("Type", .{}),
                .Data =>
                {
                    try writer.print("Data ", .{});
                    const knownDataChunkType = getKnownDataChunkType(chunk.node.chunkType);
                    // TODO:
                    // this probably needs some structure
                    // and I should solve this with reflection.
                    switch (knownDataChunkType)
                    {
                        .IHDR =>
                        {
                            switch (chunk.dataNode.ihdr)
                            {
                                .Width => try writer.print("Width", .{}),
                                .Height => try writer.print("Height", .{}),
                                .BitDepth => try writer.print("BitDepth", .{}),
                                .ColorType => try writer.print("ColorType", .{}),
                                .CompressionMethod => try writer.print("CompressionMethod", .{}),
                                .FilterMethod => try writer.print("FilterMethod", .{}),
                                .InterlaceMethod => try writer.print("InterlaceMethod", .{}),
                                .Done => {},
                            }
                        },
                        .PLTE =>
                        {
                            const byte = chunk.dataNode.plte.bytesRead;
                            try writer.print("PLTE byte {x} (color index {}, state {})", .{
                                byte,
                                byte / 3,
                                chunk.dataNode.plte.rgb,
                            });
                        },
                        .Unknown => try writer.print("?", .{}),
                    }
                },
                .CyclicRedundancyCheck => try writer.print("CyclicRedundancyCheck", .{}),
                .Done => {},
            }
        },
        .StartChunk => try writer.print("Chunk", .{}),
    }
    try writer.print("\n", .{});
}

pub fn getKnownDataChunkType(chunkType: ChunkType) KnownDataChunkType
{
    const h = struct
    {
        fn chunkTypeEquals(
            chunkType_: ChunkType,
            knownChunkType: ChunkType) bool
        {
            const a = chunkType_.bytes[1 .. 4];
            const b = knownChunkType.bytes[1 .. 4];
            return std.mem.eql(u8, a, b);
        }
    };

    switch (chunkType.bytes[0])
    {
        'I' =>
        {
            if (h.chunkTypeEquals(chunkType, KnownDataChunkTags.IHDR))
            {
                return .IHDR;
            }
        },
        'P' =>
        {
            if (h.chunkTypeEquals(chunkType, KnownDataChunkTags.PLTE))
            {
                return .PLTE;
            }
        },
        else => {},
    }
    return .Unknown;
}

pub const KnownDataChunkType = enum(u8)
{
    Unknown,
    IHDR,
    PLTE,
};

pub fn parseTopLevelNode(context: *ParserContext) !bool
{
    while (true)
    {
        if (true)
        {
            const outputStream = std.io.getStdOut().writer();
            try printStepName(outputStream, context.state);
            const offset = context.sequence.getStartOffset();
            try outputStream.print("Offset: {x}\n", .{offset});
        }

        const isDone = try parseNextNode(context);
        if (isDone)
        {
            return true;
        }
    }
}

pub fn parseNextNode(context: *ParserContext) !bool
{
    switch (context.state.*)
    {
        .Signature =>
        {
            try validateSignature(context.sequence);
            return true;
        },
        .StartChunk =>
        {
            if (context.sequence.isEmpty())
            {
                return error.NotEnoughBytes;
            }
            else
            {
                initChunkParserState(context);
            }
        },
        .Chunk =>
        {
            const isDone = try parseChunkItem(context);
            if (isDone)
            {
                return true;
            }
        },
    }
    return false;
}

fn readPngU32(sequence: *p.Sequence) !u32
{
    const value = try p.readNetworkU32(sequence);
    if (value > 0x80000000)
    {
        return error.UnsignedValueTooLarge;
    }
    return value;
}

fn readPngU32Dimension(sequence: *p.Sequence) !u32
{
    const value = readPngU32(sequence)
    catch
    {
        return error.DimensionValueTooLarge;
    };
    if (value == 0)
    {
        return error.DimensionValueIsZero;
    }
    return value;
}

pub fn parseChunkItem(context: *ParserContext) !bool
{
    var state = &context.state.Chunk;
    switch (state.key)
    {
        .Length => 
        {
            const length = try p.readNetworkU32(context.sequence);
            // The spec says it must not exceed 2^31
            if (length > 0x80000000)
            {
                return error.LengthTooLarge;
            }

            state.node.byteLength = length;
            state.key = .ChunkType;
        },
        .ChunkType =>
        {
            if (context.sequence.len() < 4)
            {
                return error.NotEnoughBytes;
            }

            var chunkType: ChunkType = undefined;

            const sequence_ = context.sequence;
            const chunkEndPosition = sequence_.getPosition(4);
            const o = sequence_.disect(chunkEndPosition);
            sequence_.* = o.right;

            o.left.copyTo(&chunkType.bytes);
            state.node.chunkType = chunkType;
            state.key = .Data;

            state.node.dataNode.base = .{
                .startPositionInFile = o.right.getStartOffset(),
                .length = state.node.byteLength,
            };

            const knownChunkType = getKnownDataChunkType(chunkType);
            if (context.ihdr == null and knownChunkType != .IHDR)
            {
                return error.IHDRChunkNotFirst;
            }

            switch (knownChunkType)
            {
                .IHDR =>
                {
                    state.dataNode = .{ .ihdr = IHDRParserStateKey.Initial };
                    state.node.dataNode.data = .{ .ihdr = std.mem.zeroes(IHDR) };
                },
                .PLTE =>
                {
                    state.dataNode = .{ .bytesSkipped = 0 };
                    state.node.dataNode.data = .{ .plte = std.mem.zeroes(PLTE) };

                    if (state.node.byteLength % 3 != 0)
                    {
                        return error.PaletteLengthNotDivisibleByThree;
                    }

                    const ihdr = context.ihdr.?;
                    switch (ihdr.colorType.flags)
                    {
                        0, ColorType.AlphaChannelUsed =>
                        {
                            return error.PaletteCannotBeUsedWithColorType;
                        },
                        else => {},
                    }

                    const representableRange = @as(u32, 1) << @as(u5, @intCast(ihdr.bitDepth));
                    const numColors = state.node.byteLength / 3;
                    if (numColors > representableRange)
                    {
                        return error.PaletteUnrepresentableWithBitDepth;
                    }
                },
                .Unknown =>
                {
                    state.dataNode = .{ .bytesSkipped = 0 };
                    state.node.dataNode.data = .{ .none = {} };
                },
            }
        },
        .Data =>
        {
            var dataNode = &state.node.dataNode;

            const done = done:
            {
                const knownChunkType = getKnownDataChunkType(state.node.chunkType);
                switch (knownChunkType)
                {
                    .IHDR =>
                    {
                        const ihdrStateKey = &state.dataNode.ihdr;
                        const ihdr = &dataNode.data.ihdr;
                        switch (ihdrStateKey.*)
                        {
                            .Width => 
                            {
                                const value = try readPngU32Dimension(context.sequence);
                                ihdr.width = value;
                                // std.debug.print("Width: {}\n", .{ ihdr.width });
                                ihdrStateKey.* = .Height;
                            },
                            .Height =>
                            {
                                const value = try readPngU32Dimension(context.sequence);
                                ihdr.height = value;
                                // std.debug.print("Height: {}\n", .{ ihdr.height });
                                ihdrStateKey.* = .BitDepth;
                            },
                            .BitDepth =>
                            {
                                const value = try p.removeFirst(context.sequence);
                                ihdr.bitDepth = value;
                                if (!isBitDepthValid(value))
                                {
                                    return error.InvalidBitDepth;
                                }
                                ihdrStateKey.* = .ColorType;
                            },
                            .ColorType =>
                            {
                                const value = try p.removeFirst(context.sequence);
                                ihdr.colorType = .{ .flags = value };
                                if (!isColorTypeValid(ihdr.colorType))
                                {
                                    return error.InvalidColorType;
                                }
                                if (!isColorTypeAllowedForBitDepth(ihdr.bitDepth, ihdr.colorType))
                                {
                                    return error.ColorTypeNotAllowedForBitDepth;
                                }
                                ihdrStateKey.* = .CompressionMethod;
                            },
                            .CompressionMethod =>
                            {
                                const value = try p.removeFirst(context.sequence);
                                ihdr.compressionMethod = value;
                                if (!isCompressionMethodValid(value))
                                {
                                    return error.InvalidCompressionMethod;
                                }
                                ihdrStateKey.* = .FilterMethod;
                            },
                            .FilterMethod =>
                            {
                                const value = try p.removeFirst(context.sequence);
                                ihdr.filterMethod = value;
                                if (!isFilterMethodValid(value))
                                {
                                    return error.InvalidFilterMethod;
                                }
                                ihdrStateKey.* = .InterlaceMethod;
                            },
                            .InterlaceMethod =>
                            {
                                const value = try p.removeFirst(context.sequence);
                                const enumValue: InterlaceMethod = @enumFromInt(value);
                                ihdr.interlaceMethod = enumValue;
                                switch (enumValue)
                                {
                                    .None, .Adam7 => {},
                                    _ => return error.InvalidInterlaceMethod,
                                }
                                ihdrStateKey.* = .Done;
                                context.ihdr = ihdr.*;
                                break :done true;
                            },
                            .Done => unreachable,
                        }
                        break :done false;
                    },
                    .PLTE =>
                    {
                        const plteState = &state.dataNode.plte;
                        const plteNode = &dataNode.data.plte;
                        const totalBytes = state.node.dataNode.base.length;

                        std.debug.assert(plteState.bytesRead <= totalBytes);

                        if (plteState.bytesRead < totalBytes)
                        {
                            const bytesToRead = totalBytes - plteState.bytesRead;
                            const bytesToReadNowCount = @min(bytesToRead, context.sequence.len());
                            if (bytesToReadNowCount == 0)
                            {
                                return error.NotEnoughBytes;
                            }

                            const byteCountToReadUntil = plteState.bytesRead + bytesToReadNowCount;

                            while (plteState.bytesRead < byteCountToReadUntil)
                            {
                                const color = color:
                                {
                                    if (plteState.rgb != .None)
                                    {
                                        plteState.rgb = RGBState.FirstColor;
                                        // We're gonna have a memory leak if we don't move the list.
                                        break :color try plteNode.colors.addOne(context.allocator);
                                    }
                                    const items = plteNode.colors.items;
                                    break :color &items[items.len - 1];
                                };

                                const colorByte = colorByte:
                                {
                                    switch (plteState.rgb)
                                    {
                                        .R => break :colorByte &color.r,
                                        .G => break :colorByte &color.g,
                                        .B => break :colorByte &color.b,
                                        .None => unreachable,
                                    }
                                };
                                colorByte.* = p.removeFirst(context.sequence) catch unreachable;

                                plteState.rgb = plteState.rgb.next();
                                plteState.bytesRead += 1;
                            }
                        }

                        break :done (plteState.bytesRead == totalBytes);
                    },
                    // Let's just skip for now.
                    .Unknown =>
                    {
                        const bytesSkipped = &state.dataNode.bytesSkipped;
                        const totalBytes = state.node.dataNode.base.length;

                        std.debug.assert(bytesSkipped.* <= totalBytes);

                        if (bytesSkipped.* < totalBytes)
                        {
                            const bytesLeftToSkip = totalBytes - bytesSkipped.*;
                            const bytesToSkipNowCount = @min(bytesLeftToSkip, context.sequence.len());
                            if (bytesToSkipNowCount == 0)
                            {
                                return error.NotEnoughBytes;
                            }
                            bytesSkipped.* += @intCast(bytesToSkipNowCount);

                            const newStart = context.sequence.getPosition(bytesToSkipNowCount);
                            context.sequence.* = context.sequence.sliceFrom(newStart);
                        }

                        break :done (bytesSkipped.* == totalBytes);
                    },
                }
            };

            if (done)
            {
                state.key = .CyclicRedundancyCheck;
            }
        },
        .CyclicRedundancyCheck =>
        {
            // Just skip for now
            const value = try p.readNetworkU32(context.sequence);
            state.node.crc = .{ .value = value };
            state.key = .Done;
        },
        .Done => unreachable,
    }
    return state.key == .Done;
}

fn initChunkParserState(context: *ParserContext) void 
{
    context.state.* = 
    .{
        .Chunk = std.mem.zeroInit(ChunkParserState, .{
            .node = std.mem.zeroInit(ChunkNode, .{
                .base = NodeBase
                {
                    .startPositionInFile = context.sequence.getStartOffset(),
                },
                .dataNode = std.mem.zeroInit(ChunkDataNode, .{
                    .data = .{ .none = {} },
                }),
            }),
            .dataNode = .{ .none = {} },
        }),
    };
}
