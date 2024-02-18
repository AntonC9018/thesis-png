const std = @import("std");
const pipelines = @import("pipelines.zig");

// What is the next expected type?
pub const ParserAction = enum(u8) 
{
    Signature = 0,
    StartChunk,
    Chunk,
};

pub const ParserState = struct
{
    chunk: ChunkParserState,
    action: ParserAction = .Signature,

    imageHeader: ?IHDR = null,
    // True after the IEND chunk has been parsed.
    isEnd: bool = false,
    // True after the first IDAT chunk data start being parsed.
    isData: bool = false,
    paletteLength: ?u32 = null,
};

pub fn isParserStateTerminal(state: *const ParserState) bool 
{
    return state.action == .StartChunk;
}

pub const ParserContext = struct
{
    state: *ParserState,
    sequence: *pipelines.Sequence,
    allocator: std.mem.Allocator,
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
        transparency: TransparencyData,
        none: void,
        gamma: Gamma,
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

pub const RGB = GenericRGB(u8);

pub const PLTE = struct
{
    colors: std.ArrayListUnmanaged(RGB),
};

pub const TransparencyKind = enum
{
    IndexedColor,
    Grayscale,
    TrueColor,
};

pub fn GenericRGB(comptime t: type) type
{
    return struct
    {
        r: t,
        g: t,
        b: t,

        const Self = @This();

        pub fn at(self: anytype, index: u8)
            switch (@TypeOf(self))
            {
                *Self => *t,
                *const Self => *const t,
                else => unreachable,
            }
        {
            return switch (index)
            {
                0 => &self.r,
                1 => &self.g,
                2 => &self.b,
                else => unreachable,
            };
        }
    };
}

const RGB16 = GenericRGB(u16);

pub const TransparencyData = union(enum)
{
    paletteEntryAlphaValues: std.ArrayListUnmanaged(u8),
    gray: u16,
    rgb: RGB16,
};

pub const Gamma = u32;

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
    transparency: TransparencyState,
};

pub const TransparencyState = union
{
    bytesRead: u32,
    rgbIndex: u2,
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
fn validateSignature(slice: *pipelines.Sequence) !void 
{
    var copy = slice.*;
    pipelines.removeFront(&copy, pngFileSignature)
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


pub const KnownDataChunkType = enum(u32)
{
    ImageHeader = tag("IHDR"),
    Palette = tag("PLTE"),
    ImageData = tag("IDAT"),
    ImageEnd = tag("IEND"),

    Transparency = tag("tRNS"),
    Gamma = tag("gAMA"),
    Chromaticity = tag("cHRM"),
    ColorSpace = tag("sRGB"),
    ICCProfile = tag("iCCP"),

    Text = tag("tEXt"),
    CompressedText = tag("zTXt"),
    InternationalText = tag("iTXt"),

    Background = tag("bKGD"),
    PhysicalPixelDimensions = tag("pHYs"),
    SignificantBits = tag("sBIT"),
    SuggestedPalette = tag("sPLT"),
    PaletteHistogram = tag("hIST"),
    LastModificationTime = tag("tIME"),
    _,

    fn tag(str: *const[4:0]u8) u32
    {
        const bytes: [4]u8 = str.*;
        return @bitCast(bytes);
    }
};

pub fn printStepName(writer: anytype, parserState: *const ParserState) !void
{
    switch (parserState.action)
    {
        .Signature => try writer.print("Signature", .{}),
        .Chunk =>
        {
            const chunk = &parserState.chunk;
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
                        .ImageHeader =>
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
                        .Palette =>
                        {
                            const byte = chunk.dataNode.plte.bytesRead;
                            try writer.print("PLTE byte {x} (color index {}, state {})", .{
                                byte,
                                byte / 3,
                                chunk.dataNode.plte.rgb,
                            });
                        },
                        else => |x| try writer.print("{any}", .{ x }),
                        // _ => try writer.print("?", .{}),
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
    return @enumFromInt(chunkType.value);
}

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
    switch (context.state.action)
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
                const offset = context.sequence.getStartOffset();
                context.state.chunk = createChunkParserState(offset);
                context.state.action = .Chunk;
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

fn readPngU32(sequence: *pipelines.Sequence) !u32
{
    const value = try pipelines.readNetworkUnsigned(sequence, u32);
    if (value > 0x80000000)
    {
        return error.UnsignedValueTooLarge;
    }
    return value;
}

fn readPngU32Dimension(sequence: *pipelines.Sequence) !u32
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
    var chunk = &context.state.chunk;
    switch (chunk.key)
    {
        .Length => 
        {
            const length = readPngU32(context.sequence)
            catch
            {
                return error.LengthValueTooLarge;
            };

            chunk.node.byteLength = length;
            chunk.key = .ChunkType;
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
            chunk.node.chunkType = chunkType;
            chunk.key = .Data;

            chunk.node.dataNode.base = .{
                .startPositionInFile = o.right.getStartOffset(),
                .length = chunk.node.byteLength,
            };

            try initChunkDataNode(context, chunkType);
        },
        .Data =>
        {
            const done = parseChunkData(context);
            if (done)
            {
                chunk.key = .CyclicRedundancyCheck;
            }
        },
        .CyclicRedundancyCheck =>
        {
            // Just skip for now
            const value = try pipelines.readNetworkU32(context.sequence);
            chunk.node.crc = .{ .value = value };
            chunk.key = .Done;
        },
        .Done => unreachable,
    }
    return chunk.key == .Done;
}


fn initChunkDataNode(context: *ParserContext, chunkType: ChunkType) !void
{
    const knownChunkType = getKnownDataChunkType(chunkType);
    if (context.state.imageHeader == null
        and knownChunkType != .ImageHeader)
    {
        return error.IHDRChunkNotFirst;
    }

    if (context.state.isData 
        and knownChunkType != .ImageEnd
        and knownChunkType != .ImageData)
    {
        return error.OnlyEndOrDataAllowedAfterIDAT;
    }

    const chunk = &context.state.chunk;
    const h = struct
    {
        fn skipChunkBytes(chunk_: *ChunkParserState) void
        {
            chunk_.dataNode = .{ .bytesSkipped = 0 };
            chunk_.node.dataNode.data = .{ .none = {} };
        }

        fn setTransparencyData(chunk_: *ChunkParserState, data: TransparencyData) void
        {
            chunk_.node.dataNode.data = .{
                .transparency = data,
            };
        }
    };

    switch (knownChunkType)
    {
        .ImageHeader =>
        {
            chunk.dataNode = .{ .ihdr = IHDRParserStateKey.Initial };
            chunk.node.dataNode.data = .{ .ihdr = std.mem.zeroes(IHDR) };
        },
        .Palette =>
        {
            chunk.dataNode = .{ .plte = std.mem.zeroes(PLTEState) };
            chunk.node.dataNode.data = .{ .plte = std.mem.zeroes(PLTE) };

            if (chunk.node.byteLength % 3 != 0)
            {
                return error.PaletteLengthNotDivisibleByThree;
            }

            const header = context.state.imageHeader.?;
            switch (header.colorType.flags)
            {
                0, ColorType.AlphaChannelUsed =>
                {
                    return error.PaletteCannotBeUsedWithColorType;
                },
                else => {},
            }

            const representableRange = @as(u32, 1) << @as(u5, @intCast(header.bitDepth));
            const numColors = chunk.node.byteLength / 3;
            if (numColors > representableRange)
            {
                return error.PaletteUnrepresentableWithBitDepth;
            }
        },
        .ImageEnd =>
        {
            const length = chunk.node.byteLength;
            if (length > 0)
            {
                return error.NonZeroLengthForIEND;
            }

            context.state.isEnd = true;
            h.skipChunkBytes(chunk);
        },
        .ImageData =>
        {
            context.state.isData = true;
            h.skipChunkBytes(chunk);
        },
        .Transparency =>
        {
            const length = chunk.node.byteLength;
            switch (context.state.imageHeader.?.colorType.flags)
            {
                ColorType.ColorUsed | ColorType.PalleteUsed =>
                {
                    if (context.state.paletteLength == null)
                    {
                        return error.TransparencyWithoutPalette;
                    }

                    const maxLength = context.state.paletteLength.?;
                    if (length > maxLength)
                    {
                        return error.TransparencyLengthExceedsPalette;
                    }

                    h.setTransparencyData(chunk, .{ .paletteEntryAlphaValues = .{} });

                    chunk.dataNode = .{ 
                        .transparency = .{ 
                            .bytesRead = 0,
                        }
                    };
                },
                // Grayscale
                0 =>
                {
                    if (length != 2)
                    {
                        error.GrayscaleTransparencyLengthMustBe2;
                    }
                    h.setTransparencyData(chunk, .{ .gray = 0 });

                    chunk.dataNode = .{ .none = {} };
                },
                // True color
                ColorType.ColorUsed =>
                {
                    if (length != 3 * 2)
                    {
                        error.TrueColorTransparencyLengthMustBe6;
                    }
                    h.setTransparencyData(chunk, .{ .rgb = std.mem.zeroes(RGB16) });

                    chunk.dataNode = .{ 
                        .transparency = .{ 
                            .rgb = .R,
                        }
                    };
                },
                else =>
                {
                    error.BadColorTypeForTransparencyChunk;
                },
            }

        },
        .Gamma =>
        {
            chunk.dataNode = .{ .none = {} };
            chunk.node.dataNode.data = .{ .gamma = 0 };
        },
        _ => h.skipChunkBytes(chunk),
    }
}

fn skipBytes(context: *ParserContext, chunk: *ChunkParserState) !bool
{
    const bytesSkipped = &chunk.dataNode.bytesSkipped;
    const totalBytes = chunk.node.dataNode.base.length;

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

    return (bytesSkipped.* == totalBytes);
}

fn removeAndProcessAsManyBytesAsAvailable(
    context: *ParserContext,
    bytesRead: *u32,
    // Must have a function each that takes in the byte.
    // Can have an optional function init that takes the count.
    functor: anytype) !bool
{
    const totalBytes = context.state.chunk.node.dataNode.base.length;
    std.debug.assert(bytesRead.* <= totalBytes);

    if (bytesRead.* == totalBytes)
    {
        return true;
    }

    const sequenceLength = context.sequence.len();
    if (sequenceLength == 0)
    {
        return error.NotEnoughBytes;
    }

    const maxBytesToRead = totalBytes - bytesRead.*;
    const bytesThatWillBeRead = @min(maxBytesToRead, sequenceLength);
    const readPosition = context.sequence.getPosition(bytesThatWillBeRead);
    const s = context.sequence.disect(readPosition);

    if (@hasDecl(@TypeOf(functor), "initCount"))
    {
        try functor.initCount(bytesThatWillBeRead);
    }

    bytesRead.* += bytesThatWillBeRead;
    context.sequence.* = s.right;

    if (@hasDecl(@TypeOf(functor), "sequence"))
    {
        functor.sequence(s.left);
    }

    if (@hasDecl(@TypeOf(functor), "each"))
    {
        const iter = pipelines.SegmentIterator.create(s.left).?;
        while (true)
        {
            const slice = iter.current();
            for (slice) |byte|
            {
                try functor.each(byte);
            }
            if (!iter.advance())
            {
                break;
            }
        }
    }

    return (bytesRead.* == totalBytes);
}

const PlteBytesProcessor = struct
{
    context: *ParserContext,
    plteState: *PLTEState,
    plteNode: *PLTE,

    const Self = @This();

    pub fn each(self: *Self, byte: u8) !void
    {
        const color = color:
        {
            if (self.plteState.rgb != .None)
            {
                self.plteState.rgb = RGBState.FirstColor;
                // We're gonna have a memory leak if we don't move the list.
                break :color try self.plteNode.colors.addOne(self.context.allocator);
            }
            const items = self.plteNode.colors.items;
            break :color &items[items.len - 1];
        };

        const colorByte = colorByte:
        {
            switch (self.plteState.rgb)
            {
                .R => break :colorByte &color.r,
                .G => break :colorByte &color.g,
                .B => break :colorByte &color.b,
                .None => unreachable,
            }
        };
        colorByte.* = byte; 

        self.plteState.rgb = self.plteState.rgb.next();
    }
};

const TransparencyBytesProcessor = struct
{
    alphaValues: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn sequence(self: *Self, seq: pipelines.Sequence) !void
    {
        const len = seq.len();
        const newItems = try self.alphaValues.addManyAsSlice(len);
        seq.copyTo(newItems);
    }
};

fn parseChunkData(context: *ParserContext) !bool
{
    const chunk = &context.state.chunk;
    const knownChunkType = getKnownDataChunkType(chunk.node.chunkType);
    const dataNode = &chunk.node.dataNode;

    switch (knownChunkType)
    {
        .ImageHeader =>
        {
            const ihdrState = &chunk.dataNode.ihdr;
            const ihdr = &dataNode.data.ihdr;
            switch (ihdrState.*)
            {
                .Width => 
                {
                    const value = try readPngU32Dimension(context.sequence);
                    ihdr.width = value;
                    // std.debug.print("Width: {}\n", .{ ihdr.width });
                    ihdrState.* = .Height;
                },
                .Height =>
                {
                    const value = try readPngU32Dimension(context.sequence);
                    ihdr.height = value;
                    // std.debug.print("Height: {}\n", .{ ihdr.height });
                    ihdrState.* = .BitDepth;
                },
                .BitDepth =>
                {
                    const value = try pipelines.removeFirst(context.sequence);
                    ihdr.bitDepth = value;
                    if (!isBitDepthValid(value))
                    {
                        return error.InvalidBitDepth;
                    }
                    ihdrState.* = .ColorType;
                },
                .ColorType =>
                {
                    const value = try pipelines.removeFirst(context.sequence);
                    ihdr.colorType = .{ .flags = value };
                    if (!isColorTypeValid(ihdr.colorType))
                    {
                        return error.InvalidColorType;
                    }
                    if (!isColorTypeAllowedForBitDepth(ihdr.bitDepth, ihdr.colorType))
                    {
                        return error.ColorTypeNotAllowedForBitDepth;
                    }
                    ihdrState.* = .CompressionMethod;
                },
                .CompressionMethod =>
                {
                    const value = try pipelines.removeFirst(context.sequence);
                    ihdr.compressionMethod = value;
                    if (!isCompressionMethodValid(value))
                    {
                        return error.InvalidCompressionMethod;
                    }
                    ihdrState.* = .FilterMethod;
                },
                .FilterMethod =>
                {
                    const value = try pipelines.removeFirst(context.sequence);
                    ihdr.filterMethod = value;
                    if (!isFilterMethodValid(value))
                    {
                        return error.InvalidFilterMethod;
                    }
                    ihdrState.* = .InterlaceMethod;
                },
                .InterlaceMethod =>
                {
                    const value = try pipelines.removeFirst(context.sequence);
                    const enumValue: InterlaceMethod = @enumFromInt(value);
                    ihdr.interlaceMethod = enumValue;
                    switch (enumValue)
                    {
                        .None, .Adam7 => {},
                        _ => return error.InvalidInterlaceMethod,
                    }
                    ihdrState.* = .Done;
                    context.state.imageHeader = ihdr.*;
                    return true;
                },
                .Done => unreachable,
            }
            return false;
        },
        .Palette =>
        {
            const plteNode = &dataNode.data.plte;
            const functor = PlteBytesProcessor
            {
                .context = context,
                .plteState = &chunk.dataNode.plte,
                .plteNode = &plteNode,
            };

            const done = try removeAndProcessAsManyBytesAsAvailable(
                context,
                &functor.plteState.bytesRead,
                functor);

            if (done)
            {
                // This can be computed prior though.
                context.state.paletteLength = plteNode.colors.items.length;
            }

            return done;
        },
        .ImageEnd =>
        {
            std.debug.assert(chunk.node.byteLength == 0);
            return true;
        },
        .ImageData => skipBytes(context, chunk),
        .Transparency =>
        {
            switch (chunk.node.dataNode.data.transparency)
            {
                .paletteEntryAlphaValues => |*alphaValues|
                {
                    const bytesRead = &chunk.dataNode.transparency.bytesRead;
                    const functor = TransparencyBytesProcessor
                    {
                        .alphaValues = alphaValues,
                        .allocator = context.allocator,
                    };

                    return try removeAndProcessAsManyBytesAsAvailable(context, bytesRead, functor);
                },
                .gray => |*gray|
                {
                    gray.* = try pipelines.readNetworkUnsigned(context.sequence, u16);
                    return true;
                },
                .rgb => |*rgb|
                {
                    const rgbIndex = &chunk.dataNode.transparency.rgbIndex;
                    while (rgbIndex.* < 2)
                    {
                        const value = try pipelines.readNetworkUnsigned(context.sequence, u16);
                        rgb.at(rgbIndex.*).* = value;
                        rgbIndex.* += 1;
                    }
                    return true;
                },
            }
        },
        .Gamma =>
        {
            // The spec doesn't say anything about this value being limited.
            dataNode.data.gamma = try pipelines.readNetworkUnsigned(context.sequence, u32);
            return true;
        },
        // Let's just skip for now.
        _ => skipBytes(context, chunk),
    }
}

pub fn createParserState() ParserState
{
    return .{
        .chunk = std.mem.zeroInit(ChunkParserState, .{
            .dataNode = .{ .none = {} },
            .node = std.mem.zeroInit(ChunkNode, .{
                .dataNode = std.mem.zeroInit(ChunkDataNode, .{
                    .data = .{ .none = {} },
                }),
            }),
        }),
    };
}

fn createChunkParserState(startOffset: usize) ChunkParserState
{
    return std.mem.zeroInit(ChunkParserState, .{
        .node = std.mem.zeroInit(ChunkNode, .{
            .base = NodeBase
            {
                .startPositionInFile = startOffset,
            },
            .dataNode = std.mem.zeroInit(ChunkDataNode, .{
                .data = .{ .none = {} },
            }),
        }),
        .dataNode = .{ .none = {} },
    });
}

