const std = @import("std");
const pipelines = @import("pipelines.zig");
const zlib = @import("zlib/zlib.zig");

// What is the next expected type?
pub const Action = enum(u8) 
{
    Signature = 0,
    StartChunk,
    Chunk,
};

pub const State = struct
{
    chunk: ChunkState,
    action: Action = .Signature,

    imageHeader: ?IHDR = null,
    // True after the IEND chunk has been parsed.
    isEnd: bool = false,
    // True after the first IDAT chunk data start being parsed.
    isData: bool = false,
    paletteLength: ?u32 = null,

    imageData: ImageData = .{},
};

pub fn isParserStateTerminal(state: *const State) bool 
{
    return state.action == .StartChunk;
}

pub const Settings = struct
{
    logChunkStart: bool,
};

pub const Context = struct
{
    state: *State,
    sequence: *pipelines.Sequence,
    allocator: std.mem.Allocator,
    settings: *const Settings,
};

pub const ChunkAction = enum 
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
        primaryChroms: PrimaryChroms,
        renderingIntent: RenderingIntent,
        iccProfile: ICCProfile,
        text: TextData,
    },
};

// Of course, this will need to be reworked once I do the tree range optimizations
pub const ImageData = struct
{
    // Just read the raw bytes for now
    bytes: std.ArrayListUnmanaged(u8) = .{},
    zlib: zlib.State = .{},
};

pub const TextData = struct
{
    keyword: std.ArrayListUnmanaged(u8) = .{},
    text: std.ArrayListUnmanaged(u8) = .{},
};

pub const ICCProfile = struct
{
    name: std.ArrayListUnmanaged(u8) = .{},
    decompressedProfile: std.ArrayListUnmanaged(u8) = .{},
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

pub const ChromVector = struct
{
    values: [2]u32,

    fn _resultType(comptime ownType: type) type
    {
        return switch (ownType)
        {
            *ChromVector => *u32,
            *const ChromVector => *const u32,
            else => unreachable,
        };
    }

    pub fn x(self: anytype) _resultType(@TypeOf(self))
    {
        return &self.values[0];
    }
    pub fn y(self: anytype) _resultType(@TypeOf(self))
    {
        return &self.values[1];
    }
};

pub const PrimaryChroms = struct
{
    values: [4]ChromVector,

    fn _resultType(comptime ownType: type) type
    {
        return switch (ownType)
        {
            *PrimaryChroms => *ChromVector,
            *const PrimaryChroms => *const ChromVector,
            else => unreachable,
        };
    }

    pub fn whitePoint(self: anytype) _resultType(@TypeOf(self))
    {
        return &self.values[0];
    }
    pub fn red(self: anytype) _resultType(@TypeOf(self))
    {
        return &self.values[1];
    }
    pub fn green(self: anytype) _resultType(@TypeOf(self))
    {
        return &self.values[2];
    }
    pub fn blue(self: anytype) _resultType(@TypeOf(self))
    {
        return &self.values[3];
    }
};

pub const RenderingIntent = enum(u8)
{
    Perceptual = 0,
    RelativeColorimetric = 1,
    Saturation = 2,
    AbsoluteColorimetric = 3,
    _,

    pub fn isValid(self: RenderingIntent) bool
    {
        const max = @intFromEnum(RenderingIntent.AbsoluteColorimetric);
        return @intFromEnum(self) <= max;
    }
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

pub const ChunkState = struct
{
    key: ChunkAction = .Length,
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
    primaryChrom: PrimaryChromState,
    iccProfile: ICCProfileState,
    text: TextState,
    compressedText: CompressedTextState,
    imageData: ImageDataState,
};

pub const ImageDataState = struct
{
    // TODO: Unite this logic, making the sequence automatically cut.
    bytesRead: u32 = 0,
};

pub const CompressedTextAction = enum
{
    Keyword,
    CompressionMethod,
    Text,
};

pub const CompressedTextState = struct
{
    bytesRead: u32 = 0,
    action: CompressedTextAction = .Keyword,
    zlib: zlib.State,
};

pub const TextAction = enum
{
    Keyword,
    Text,
};

pub const TextState = struct
{
    bytesRead: u32 = 0,
    action: TextAction = .Keyword,
    text: std.ArrayListUnmanaged(u8) = .{},
};

pub const ICCProfileAction = enum
{
    ProfileName,
    CompressionMethod,
    CompressedData,
};

pub const ICCProfileState = struct
{
    action: ICCProfileAction = .ProfileName,
    bytes: std.ArrayListUnmanaged(u8) = .{},
    zlib: zlib.State,
};

pub const TransparencyState = union
{
    bytesRead: u32,
    rgbIndex: u2,
};

pub const PrimaryChromState = struct
{
    value: u8,

    pub fn vector(self: PrimaryChromState) u8
    {
        return self.value / 2;
    }
    pub fn coord(self: PrimaryChromState) u8
    {
        return self.value % 2;
    }
    pub fn notDone(self: PrimaryChromState) bool
    {
        return self.value < 8;
    }
    pub fn advance(self: *PrimaryChromState) void
    {
        self.value += 1;
    }
};

pub const IHDRParserStateKey = enum(u32)
{
    Width,
    Height,
    BitDepth,
    ColorType,
    CompressionMethod,
    FilterMethod,
    InterlaceMethod,
    Done,

    pub const Initial = .Width;
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
    PrimaryChrom = tag("cHRM"),
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

pub fn printStepName(writer: anytype, parserState: *const State) !void
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
                        .ImageData =>
                        {
                            const z = &parserState.imageData.zlib;
                            try printZlibState(z, writer);
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

fn printZlibState(z: *const zlib.State, writer: anytype) !void
{
    switch (z.action)
    {
        .CompressedData =>
        {
            const deflate = &z.decompressor.deflate;
            try writer.print("CompressedData {} ", .{ deflate.action });
            switch (deflate.action)
            {
                else => {},
                .BlockInit =>
                {
                    switch (deflate.blockState)
                    {
                        .DynamicHuffman => |dyn|
                        {
                            try writer.print("{any}", .{ dyn.codeDecoding });
                        },
                        else => {},
                    }
                },
                .DecompressionLoop =>
                {
                    switch (deflate.blockState)
                    {
                        .DynamicHuffman => |dyn|
                        {
                            try writer.print("dynamic {any}", .{ dyn.decompression });
                        },
                        .FixedHuffman => |fixed|
                        {
                            try writer.print("fixed: {any}", .{ fixed });
                            if (deflate.lastSymbol) |ls|
                            {
                                try writer.print("\nlast symbol: {any}", .{ ls });
                            }
                        },
                        else => try writer.print("{}", .{ deflate.blockState }),
                    }
                }
            }
        },
        else => |x| try writer.print("{}", .{ x }),
    }
}

pub fn getKnownDataChunkType(chunkType: ChunkType) KnownDataChunkType
{
    return @enumFromInt(chunkType.value);
}

pub fn parseTopLevelNode(context: *const Context) !bool
{
    while (true)
    {
        if (context.settings.logChunkStart)
        {
            const outputStream = std.io.getStdOut().writer();
            try printStepName(outputStream, context.state);
            const offset = context.sequence.getStartOffset();
            try outputStream.print("Offset: {x}", .{offset});

            {
                const z = &context.state.imageData.zlib;
                if (z.action == .CompressedData)
                {
                    try outputStream.print(", Data bit offset: {d}", .{z.decompressor.deflate.bitOffset});
                }
            }
            try outputStream.print("\n", .{});

            const maxBytesToPrint = 10;
            const numBytesWillPrint = @min(context.sequence.len(), maxBytesToPrint);
            const s = context.sequence.sliceToExclusive(context.sequence.getPosition(numBytesWillPrint));
            if (s.len() > 0)
            {
                var iter = s.iterate().?;
                while (true)
                {
                    for (iter.current()) |byte|
                    {
                        switch (byte)
                        {
                            // ' ' ... '~' => try outputStream.print("{c} ", .{ byte }),
                            else => try outputStream.print("{x:02} ", .{ byte }),
                        }
                    }

                    if (!iter.advance())
                    {
                        break;
                    }
                }
                try outputStream.print("\n", .{});
            }
            try outputStream.print("\n", .{});
        }

        const isDone = try parseNextNode(context);
        if (isDone)
        {
            return true;
        }
    }
}

pub fn parseNextNode(context: *const Context) !bool
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

pub fn parseChunkItem(context: *const Context) !bool
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
            const done = try parseChunkData(context);
            if (done)
            {
                chunk.key = .CyclicRedundancyCheck;
            }
        },
        .CyclicRedundancyCheck =>
        {
            // Just skip for now
            const value = try pipelines.readNetworkUnsigned(context.sequence, u32);
            chunk.node.crc = .{ .value = value };
            chunk.key = .Done;
        },
        .Done => unreachable,
    }
    return chunk.key == .Done;
}


// TODO:
// Check if the size specified matches the expected size.
// If the size of the chunk is dynamic, resize
// the sequence appropriately and reinterpret error.NotEnoughBytes.
fn initChunkDataNode(context: *const Context, chunkType: ChunkType) !void
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
        fn skipChunkBytes(chunk_: *ChunkState) void
        {
            chunk_.dataNode = .{ .bytesSkipped = 0 };
            chunk_.node.dataNode.data = .{ .none = {} };
        }

        fn setTransparencyData(chunk_: *ChunkState, data: TransparencyData) void
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
            if (!context.state.isData)
            {
                context.state.isData = true;
            }
            chunk.dataNode = .{ .imageData = .{} };
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
                        return error.GrayscaleTransparencyLengthMustBe2;
                    }
                    h.setTransparencyData(chunk, .{ .gray = 0 });

                    chunk.dataNode = .{ .none = {} };
                },
                // True color
                ColorType.ColorUsed =>
                {
                    if (length != 3 * 2)
                    {
                        return error.TrueColorTransparencyLengthMustBe6;
                    }
                    h.setTransparencyData(chunk, .{ .rgb = std.mem.zeroes(RGB16) });

                    chunk.dataNode = .{ .transparency = .{ .rgbIndex = 0 } };
                },
                else =>
                {
                    return error.BadColorTypeForTransparencyChunk;
                },
            }

        },
        .Gamma =>
        {
            chunk.dataNode = .{ .none = {} };
            chunk.node.dataNode.data = .{ .gamma = 0 };
        },
        .PrimaryChrom =>
        {
            chunk.dataNode = .{ .primaryChrom = .{ .value = 0 } };
            chunk.node.dataNode.data = .{ .primaryChroms = std.mem.zeroes(PrimaryChroms) };
        },
        .ColorSpace =>
        {
            chunk.dataNode = .{ .none = {} };
            chunk.node.dataNode.data = .{ .renderingIntent = std.mem.zeroes(RenderingIntent) };
        },
        .ICCProfile =>
        {
            chunk.dataNode = .{
                .iccProfile = .{
                    .zlib = .{},
                },
            };
            chunk.node.dataNode.data = .{ .iccProfile = .{} };
        },
        .Text =>
        {
            chunk.dataNode = .{
                .text = .{},
            };
            chunk.node.dataNode.data = .{
                .text = .{},
            };
        },
        .CompressedText =>
        {
            chunk.dataNode = .{
                .compressedText = .{
                    .zlib = .{},
                },
            };
            chunk.node.dataNode.data = .{
                .text = .{},
            };
        },
        else => h.skipChunkBytes(chunk),
    }
}

fn skipBytes(context: *const Context, chunk: *ChunkState) !bool
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
    context: *const Context,
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
    const bytesThatWillBeRead: u32 = @intCast(@min(maxBytesToRead, sequenceLength));
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
        try functor.sequence(s.left);
    }

    if (@hasDecl(@TypeOf(functor), "each"))
    {
        var iter = pipelines.SegmentIterator.create(&s.left).?;
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
    context: *const Context,
    plteState: *PLTEState,
    plteNode: *PLTE,

    pub fn each(self: *const PlteBytesProcessor, byte: u8) !void
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

    pub fn sequence(self: *const TransparencyBytesProcessor, seq: pipelines.Sequence) !void
    {
        const len = seq.len();
        const newItems = try self.alphaValues.addManyAsSlice(self.allocator, len);
        seq.copyTo(newItems);
    }
};

const TextBytesProcessor = struct
{
    text: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn initCount(self: *const TextBytesProcessor, count: u32) !void
    {
        try self.text.ensureTotalCapacity(self.allocator, count);
    }

    pub fn sequence(self: *const TextBytesProcessor, seq: pipelines.Sequence) !void
    {
        const len = seq.len();
        const newItems = try self.text.addManyAsSlice(self.allocator, len);
        seq.copyTo(newItems);
    }
};

fn readNullTerminatedText(
    context: *const Context,
    output: *std.ArrayListUnmanaged(u8),
    maxLenExcludingNull: usize) !void
{
    const sequence = context.sequence;

    if (output.items.len == maxLenExcludingNull)
    {
        return;
    }

    var iter = sequence.iterate() orelse return error.NotEnoughBytes;

    while (true)
    {
        const slice = iter.current();
        const bytesLeftToRead = maxLenExcludingNull - output.items.len;
        const maxBytesWillRead = @min(slice.len, bytesLeftToRead);

        const nullBytePos = n:
        {
            // +1 because the null termination might be outside the bytes of the string.
            for (0 .. maxBytesWillRead + 1) |i|
            {
                const byte = slice[i];
                if (byte == 0)
                {
                    break :n i;
                }
            }
            break :n null;
        };

        if (nullBytePos == null)
        {
            // Just this is fine by itself if the null byte is in the next segment.
            if (maxBytesWillRead == bytesLeftToRead
                and maxBytesWillRead < slice.len)
            {
                // TODO: Should we consume the bytes still in case of error?
                return error.ExpectedNullByteAtEndOfString;
            }

            // We were only looking for the last null byte on this iteration,
            // but didn't find it.
            if (maxBytesWillRead == 0)
            {
                return error.ExpectedNullByteAtEndOfString;
            }
        }

        const copyUntilPos = nullBytePos orelse maxBytesWillRead;
        const sourceSlice = slice[0 .. copyUntilPos];

        const containsConsecutiveOrLeadingSpaces = sp:
        {
            if (copyUntilPos == 0)
            {
                break :sp false;
            }

            if (output.items.len == 0)
            {
                if (slice[0] == ' ')
                {
                    break :sp true;
                }
            }
            else
            {
                var isPreviousSpace = output.items[output.items.len - 1] == ' ';
                for (sourceSlice) |byte|
                {
                    const isSpace = byte == ' ';
                    if (isSpace and isPreviousSpace)
                    {
                        break :sp true;
                    }
                    isPreviousSpace = isSpace;
                }
            }

            break :sp false;
        };
        const nonPrintableCharacterIndex = ch:
        {
            for (0 .., sourceSlice) |i, byte|
            {
                switch (byte)
                {
                    ' ' ... '~' => {},
                    161 ... 255 => {},
                    else => break :ch i,
                }
            }
            break :ch null;
        };

        const anyError = containsConsecutiveOrLeadingSpaces or nonPrintableCharacterIndex != null;
        if (anyError)
        {
            const offset = offset:
            {
                if (containsConsecutiveOrLeadingSpaces)
                {
                    break :offset 0;
                }
                if (nonPrintableCharacterIndex) |i|
                {
                    break :offset i;
                }
                unreachable;
            };

            const newStart = iter.getCurrentPosition().add(@intCast(offset));
            sequence.* = sequence.sliceFrom(newStart);

            if (containsConsecutiveOrLeadingSpaces)
            {
                return error.ContainsConsecutiveOrLeadingSpaces;
            }
            if (nonPrintableCharacterIndex != null)
            {
                return error.NonPrintableCharacter;
            }
        }

        if (copyUntilPos > 0)
        {
            const destinationSlice = try output.addManyAsSlice(context.allocator, copyUntilPos);
            @memcpy(destinationSlice, sourceSlice);
        }

        if (nullBytePos) |readUntilPos|
        {
            // We want to consume the null termination as well.
            const newStart = iter.getCurrentPosition().add(@intCast(readUntilPos + 1));
            // Update the sequence to this position.
            sequence.* = sequence.sliceFrom(newStart);
            return;
        }

        if (!iter.advance())
        {
            sequence.* = sequence.sliceFrom(sequence.end());
            return error.NotEnoughBytes;
        }
    }
}

fn readZlibData(
    context: anytype,
    state: *zlib.State,
    output: *std.ArrayListUnmanaged(u8)) !bool
{
    var outputBuffer = zlib.OutputBuffer
    {
        .allocator = context.allocator,
        .array = output,
        .windowSize = &state.windowSize,
    };
    const common = zlib.CommonContext
    {
        .allocator = context.allocator,
        .output = &outputBuffer,
        .sequence = context.sequence,
    };
    const zlibContext = zlib.Context
    {
        .common = &common,
        .state = state,
    };
    const isDone = try zlib.decode(&zlibContext);
    if (isDone)
    {
        return true;
    }
    return false;
}

fn readKeywordText(context: *const Context, keyword: *std.ArrayListUnmanaged(u8), bytesRead: *u32) !void
{
    const maxLen = 80;
    try readNullTerminatedText(context, keyword, maxLen);
    // TODO: This is kind of dumb. It should be kept track of at a higher level.
    bytesRead.* = @intCast(keyword.items.len + 1);
}

fn parseChunkData(context: *const Context) !bool
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
            const plteState = &chunk.dataNode.plte;

            const functor = PlteBytesProcessor
            {
                .context = context,
                .plteState = plteState,
                .plteNode = plteNode,
            };

            const done = try removeAndProcessAsManyBytesAsAvailable(
                context,
                &plteState.bytesRead,
                functor);

            if (done)
            {
                // This can be computed prior though.
                context.state.paletteLength = @intCast(plteNode.colors.items.len);
            }

            return done;
        },
        .ImageEnd =>
        {
            std.debug.assert(chunk.node.byteLength == 0);
            return true;
        },
        .ImageData =>
        {
            const imageData = &context.state.imageData;
            const bytesRead = &chunk.dataNode.imageData.bytesRead;
            const bytesLeftToRead = chunk.node.byteLength - bytesRead.*;

            var sequence = context.sequence.*;
            const newLen = @min(sequence.len(), bytesLeftToRead);
            sequence = sequence.sliceToExclusive(sequence.getPosition(newLen));

            defer
            {
                const lenChange = newLen - sequence.len();
                bytesRead.* += @intCast(lenChange);

                context.sequence.* = context.sequence.sliceFrom(sequence.start());
            }

            const readContext = .{
                .allocator = context.allocator,
                .sequence = &sequence,
            };

            // This is actually a bit wrong, because the datastream can wrap at any point,
            // we have to handle chunk boundaries with a second level of wrapping.
            // Might have to hijack the pipeline abstractions.
            _ = readZlibData(readContext, &imageData.zlib, &imageData.bytes)
                catch |err|
                {
                    if (err != error.NotEnoughBytes)
                    {
                        return err;
                    }

                    if (newLen == bytesLeftToRead and sequence.len() == 0)
                    {
                        return true;
                    }

                    return error.NotEnoughBytes;
                };
            return sequence.len() == 0;
        },
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
        .PrimaryChrom =>
        {
            const chromState = &chunk.dataNode.primaryChrom;
            const primaryChroms = &dataNode.data.primaryChroms;
            while (chromState.notDone())
            {
                const value = try pipelines.readNetworkUnsigned(context.sequence, u32);

                const vector = chromState.vector();
                const index = chromState.coord();
                const targetPointer = &primaryChroms.values[vector].values[index];
                targetPointer.* = value;

                chromState.advance();
            }
            return true;
        },
        .ColorSpace =>
        {
            const value = try pipelines.removeFirst(context.sequence);
            const e: RenderingIntent = @enumFromInt(value);
            dataNode.data.renderingIntent = e;
            if (!e.isValid())
            {
                return error.InvalidRenderingIntent;
            }
            return true;
        },
        .ICCProfile =>
        {
            const state = &chunk.dataNode.iccProfile;
            const node = &dataNode.data.iccProfile;

            switch (state.action)
            {
                .ProfileName =>
                {
                    const maxNameLen = 80;
                    try readNullTerminatedText(context, &node.name, maxNameLen);
                    state.action = .CompressionMethod;
                    return false;
                },
                .CompressionMethod =>
                {
                    const compressionMethod = try pipelines.removeFirst(context.sequence);
                    if (compressionMethod != 0)
                    {
                        return error.InvalidCompressionMethod;
                    }
                    state.action = .CompressedData;
                    return false;
                },
                .CompressedData =>
                {
                    const isDone = try readZlibData(context, &state.zlib, &node.decompressedProfile);
                    return isDone;
                },
            }
        },
        .Text =>
        {
            const state = &chunk.dataNode.text;
            const node = &dataNode.data.text;
            switch (state.action)
            {
                .Keyword =>
                {
                    try readKeywordText(context, &node.keyword, &state.bytesRead);
                    state.action = .Text;
                    return false;
                },
                .Text =>
                {
                    const bytesRead = &state.bytesRead;
                    const functor = TextBytesProcessor
                    {
                        .text = &state.text,
                        .allocator = context.allocator,
                    };

                    const done = try removeAndProcessAsManyBytesAsAvailable(context, bytesRead, functor);
                    return done;
                },
            }
        },
        .CompressedText =>
        {
            const state = &chunk.dataNode.compressedText;
            const node = &dataNode.data.text;
            switch (state.action)
            {
                .Keyword =>
                {
                    try readKeywordText(context, &node.keyword, &state.bytesRead);
                    state.action = .CompressionMethod;
                    return false;
                },
                .CompressionMethod =>
                {
                    const value = try pipelines.removeFirst(context.sequence);
                    // Maybe store it?
                    if (value != 0)
                    {
                        return error.UnsupportedCompressionMethod;
                    }
                    state.action = .Text;
                    return false;
                },
                .Text =>
                {
                    const isDone = try readZlibData(context, &state.zlib, &node.text);
                    return isDone;
                },
            }

        },
        // Let's just skip for now.
        else => return try skipBytes(context, chunk),
    }
}

pub fn createParserState() State
{
    return .{
        .chunk = std.mem.zeroInit(ChunkState, .{
            .dataNode = .{ .none = {} },
            .node = std.mem.zeroInit(ChunkNode, .{
                .dataNode = std.mem.zeroInit(ChunkDataNode, .{
                    .data = .{ .none = {} },
                }),
            }),
        }),
    };
}

fn createChunkParserState(startOffset: usize) ChunkState
{
    return std.mem.zeroInit(ChunkState, .{
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

