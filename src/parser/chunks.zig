const common = @import("common.zig");
const std = common.std;
const pipelines = common.pipelines;
const zlib = common.zlib;
const utils = common.utils;

pub const ChunkData = union
{ 
    none: void,
    imageHeader: ImageHeader,
    palette: Palette,
    transparency: TransparencyData,
    gamma: Gamma,
    primaryChroms: PrimaryChroms,
    renderingIntent: RenderingIntent,
    iccProfile: ICCProfile,
    text: TextData,
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

pub const ImageHeader = struct
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

pub const Palette = struct
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

fn getSampleDepth(ihdr: ImageHeader) u8
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

pub const ChunkDataState = struct
{
    action: common.Initiable(ChunkDataAction),
    value: union
    {
        none: void,
        bytesSkipped: u32,
        palette: PaletteState,
        transparency: TransparencyState,
        primaryChrom: PrimaryChromState,
        iccProfile: ICCProfileState,
        text: TextState,
        compressedText: CompressedTextState,
        imageData: ImageDataState,
    },
};

pub const TaggedChunkDataAction = union(ChunkType)
{
    ImageHeader: *ImageHeaderAction,
    Palette: void, // Only RGB
    ImageData: void, // Only Zlib
    ImageEnd: void, // No bytes

    Transparency: *TransparencyAction, // Only RGB
    Gamma: void, // Only value
    PrimaryChrom: void, // TODO: I don't remember what it does
    ColorSpace: void, // Only rendering intent
    ICCProfile: *ICCProfileAction,

    Text: *TextAction,
    CompressedText: *CompressedTextAction,
    InternationalText: void, // TODO:

    // TODO:
    Background: void,
    PhysicalPixelDimensions: void,
    SignificantBits: void,
    SuggestedPalette: void,
    PaletteHistogram: void,
    LastModificationTime: void,

    _: void,
};

pub const ChunkDataAction: type = b:
{
    var info = @typeInfo(TaggedChunkDataAction);
    info.Union.tag_type = null;
    for (info.Union.fields) |*f|
    {
        f.type = newType:
        {
            const pointerOrVoid = f.type;
            if (pointerOrVoid == void)
            {
                break :newType void;
            }
            const pointerInfo = @typeInfo(pointerOrVoid);
            break :newType pointerInfo.Pointer.child;
        };
    }
    break :b @Type(info);
};

pub const TaggedChunkDataStatePointer = union(ChunkType)
{
    ImageHeader: void,
    Palette: *PaletteState,
    ImageData: *ImageDataState,
    ImageEnd: void,

    Transparency: *TransparencyState,
    Gamma: void,
    PrimaryChrom: *PrimaryChromState,
    ColorSpace: void,
    ICCProfile: *ICCProfileState,

    Text: *TextState,
    CompressedText: *CompressedTextState,
    InternationalText: void,

    Background: void,
    PhysicalPixelDimensions: void,
    SignificantBits: void,
    SuggestedPalette: void,
    PaletteHistogram: void,
    LastModificationTime: void,
    _: void,
};

pub fn ActionAndState(Action: type, State: type) type
{
    return struct
    {
        action: common.InitiableThroughPointer(Action),
        state: *State,

        pub fn actionKey(self: *const @This()) Action
        {
            return self.action.keyPointer().*;
        }

        pub fn resetAction(self: *@This(), newAction: Action) void
        {
            self.action.keyPointer().* = newAction;
            self.action.initializedPointer().* = false;
        }
    };
}

const TransparencyAction = union(enum)
{
    RGB: RGBAction,
    none: void,
};

// Not generated with reflection, for better LSP experience.
const TaggedNodeDataActionAndState = union(enum)
{
    ImageHeader: ActionAndState(ImageHeaderAction, void),
    Palette: ActionAndState(void, PaletteState), // Only RGB
    ImageData: ActionAndState(void, ImageDataState), // Only Zlib
    ImageEnd: ActionAndState(void, void), // No bytes

    Transparency: ActionAndState(TransparencyAction, TransparencyState), // Only RGB
    Gamma: ActionAndState(void, void), // Only value
    PrimaryChrom: ActionAndState(void, PrimaryChromState), // TODO: I don't remember what it does
    ColorSpace: ActionAndState(void, void), // Only rendering intent
    ICCProfile: ActionAndState(ICCProfileAction, ICCProfileState),

    Text: ActionAndState(TextAction, TextState),
    CompressedText: ActionAndState(CompressedTextAction, CompressedTextState),
    InternationalText: ActionAndState(void, void), // TODO:

    // TODO:
    Background: ActionAndState(void, void),
    PhysicalPixelDimensions: ActionAndState(void, void),
    SignificantBits: ActionAndState(void, void),
    SuggestedPalette: ActionAndState(void, void),
    PaletteHistogram: ActionAndState(void, void),
    LastModificationTime: ActionAndState(void, void),
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
    bytes: std.ArrayListUnmanaged(u8) = .{},
    zlib: zlib.State,
};


pub const TransparencyState = struct
{
    bytesRead: u32,
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
    pub fn done(self: PrimaryChromState) bool
    {
        return self.value == 8;
    }
    pub fn advance(self: *PrimaryChromState) void
    {
        self.value += 1;
    }
};

pub const ImageHeaderAction = enum(u32)
{
    Width,
    Height,
    BitDepth,
    ColorType,
    CompressionMethod,
    FilterMethod,
    InterlaceMethod,

    pub const Initial = .Width;
};

pub const PaletteState = struct
{
    bytesRead: u32,
RGBAction = .R,
};

pub const RGBAction = enum
{
    R,
    G,
    B,

    pub const FirstColor: RGBAction = .R;

    pub fn next(self: RGBAction) ?RGBAction
    {
        if (self == .B)
        {
            return null;
        }

        return @enumFromInt(@intFromEnum(self) + 1);
    }
};

const ChunkTypeMetadataMask = struct 
{
    mask: RawChunkType,
    
    pub fn ancillary() ChunkTypeMetadataMask 
    {
        var result: RawChunkType = {};
        result.bytes[0] = 0x20;
        return result;
    }
    pub fn private() ChunkTypeMetadataMask 
    {
        var result: RawChunkType = {};
        result.bytes[1] = 0x20;
        return result;
    }
    pub fn safeToCopy() ChunkTypeMetadataMask 
    {
        var result: RawChunkType = {};
        result.bytes[3] = 0x20;
        return result;
    }

    pub fn check(self: ChunkTypeMetadataMask, chunkType: RawChunkType) bool 
    {
        return (chunkType.value & self.mask.value) == self.mask.value;
    }
    pub fn set(self: ChunkTypeMetadataMask, chunkType: RawChunkType) RawChunkType 
    {
        return RawChunkType { .value = chunkType.value | self.mask.value, };
    }
    pub fn unset(self: ChunkTypeMetadataMask, chunkType: RawChunkType) RawChunkType 
    {
        return RawChunkType { .value = chunkType.value & (~self.mask.value), };
    }
};

pub const RawChunkType = extern union 
{
    bytes: [4]u8,
    value: u32,
};

pub const ChunkType = enum(u32)
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

    pub fn getString(self: ChunkType) [4]u8
    {
        return @bitCast(@intFromEnum(self));
    }
};

// TODO:
// Check if the size specified matches the expected size.
// If the size of the chunk is dynamic, resize
// the sequence appropriately and reinterpret error.NotEnoughBytes.
pub fn initChunkDataNode(context: *const common.Context, chunkType: ChunkType) !void
{
    const chunk = &context.state.chunk;
    const h = struct
    {
        fn skipChunkBytes(chunk_: *common.ChunkState) void
        {
            chunk_.dataState = .{ .bytesSkipped = 0 };
            chunk_.object.data = .{ .none = {} };
        }

        fn setTransparencyData(chunk_: *common.ChunkState, data: TransparencyData) void
        {
            chunk_.object.data = .{
                .transparency = data,
            };
        }
    };

    switch (chunkType)
    {
        .ImageHeader =>
        {
            chunk.dataState = .{ .imageHeader = ImageHeaderAction.Initial };
            chunk.object.data = .{ .imageHeader = std.mem.zeroes(ImageHeader) };
        },
        .Palette =>
        {
            chunk.dataState = .{ .palette = std.mem.zeroes(PaletteState) };
            chunk.object.data = .{ .palette = std.mem.zeroes(Palette) };

            if (chunk.object.dataByteLen % 3 != 0)
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
            const numColors = chunk.object.dataByteLen / 3;
            if (numColors > representableRange)
            {
                return error.PaletteUnrepresentableWithBitDepth;
            }
        },
        .ImageEnd =>
        {
            const length = chunk.object.dataByteLen;
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
            chunk.dataState = .{ .imageData = .{} };
        },
        .Transparency =>
        {
            const length = chunk.object.dataByteLen;
            switch (context.state.imageHeader.?.colorType.flags)
            {
                ColorType.ColorUsed | ColorType.PalleteUsed =>
                {
                    if (context.state.paletteLen == null)
                    {
                        return error.TransparencyWithoutPalette;
                    }

                    const maxLength = context.state.paletteLen.?;
                    if (length > maxLength)
                    {
                        return error.TransparencyLengthExceedsPalette;
                    }

                    h.setTransparencyData(chunk, .{ .paletteEntryAlphaValues = .{} });

                    chunk.dataState = .{ 
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

                    chunk.dataState = .{ .none = {} };
                },
                // True color
                ColorType.ColorUsed =>
                {
                    if (length != 3 * 2)
                    {
                        return error.TrueColorTransparencyLengthMustBe6;
                    }
                    h.setTransparencyData(chunk, .{ .rgb = std.mem.zeroes(RGB16) });

                    chunk.dataState = .{ 
                        .transparency = .{ 
                            .rgbAction = RGBAction.FirstColor,
                        },
                    };
                },
                else =>
                {
                    return error.BadColorTypeForTransparencyChunk;
                },
            }

        },
        .Gamma =>
        {
            chunk.dataState = .{ .none = {} };
            chunk.object.data = .{ .gamma = 0 };
        },
        .PrimaryChrom =>
        {
            chunk.dataState = .{ .primaryChrom = .{ .value = 0 } };
            chunk.object.data = .{ .primaryChroms = std.mem.zeroes(PrimaryChroms) };
        },
        .ColorSpace =>
        {
            chunk.dataState = .{ .none = {} };
            chunk.object.data = .{ .renderingIntent = std.mem.zeroes(RenderingIntent) };
        },
        .ICCProfile =>
        {
            chunk.dataState = .{
                .iccProfile = .{
                    .zlib = .{},
                },
            };
            chunk.object.data = .{ .iccProfile = .{} };
        },
        .Text =>
        {
            chunk.dataState = .{
                .text = .{},
            };
            chunk.object.data = .{
                .text = .{},
            };
        },
        .CompressedText =>
        {
            chunk.dataState = .{
                .compressedText = .{
                    .zlib = .{},
                },
            };
            chunk.object.data = .{
                .text = .{},
            };
        },
        else => h.skipChunkBytes(chunk),
    }
}

pub fn getKnownDataChunkType(chunkType: RawChunkType) ChunkType
{
    return @enumFromInt(chunkType.value);
}

pub const DataNodeParserState = union
{
    ihdr: ImageHeaderAction,
    bytesSkipped: u32,
    plte: PaletteState, 
    none: void,
    transparency: TransparencyState,
    primaryChrom: PrimaryChromState,
    iccProfile: ICCProfileState,
    text: TextState,
    compressedText: CompressedTextState,
    imageData: ImageDataState,
};

const PaletteBytesProcessor = struct
{
    context: *const common.Context,
    state: *PaletteState,
    data: *Palette,

    const InitStateForAction = struct
    {
        colors: *std.ArrayListUnmanaged(RGB),
        allocator: std.mem.Allocator,

        fn execute(self: *InitStateForAction) !void
        {
            // We're gonna have a memory leak if we don't move the list.
            _ = self.colors.addOne(self.allocator);
        }
    };

    pub fn each(self: *const PaletteBytesProcessor, byte: u8) !void
    {
        const action = &self.state.rgbAction;
        const color = color:
        {
            try common.initStateForAction(self.context, action, InitStateForAction
            {
                .colors = &self.data.colors,
                .allocator = self.context.allocator,
            });

            const items = self.data.colors.items;
            break :color &items[items.len - 1];
        };

        const colorByte = colorByte:
        {
            switch (action)
            {
                .R => break :colorByte &color.r,
                .G => break :colorByte &color.g,
                .B => break :colorByte &color.b,
            }
        };
        colorByte.* = byte; 

        // Advance state
        {
            if (action.key.next()) |next|
            {
                action.key = next;
            }
            else
            {
                action.key = RGBAction.FirstColor;
                action.initialized = false;
            }
        }
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

    pub fn each(self: *const TransparencyBytesProcessor, byte: u8) !void
    {
        try self.alphaValues.append(self.allocator, byte);
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

pub fn getActiveDataAction(state: *const common.ChunkState) TaggedChunkDataAction
{
    switch (state.object.type)
    {
        inline else => |k|
        {
            const resultInfo = @typeInfo(TaggedChunkDataAction);
            for (resultInfo.Union.fields) |f|
            {
                if (@field(ChunkType, f.name) == k)
                {
                    return @unionInit(TaggedChunkDataAction, f.name,
                        &@field(state.dataState.action.key, f.name));
                }
            }
        }
    }
}

pub fn getActiveChunkDataActionAndState(state: *const common.ChunkState) TaggedNodeDataActionAndState
{
    const action = getActiveDataAction(state);
    const state_ = getActiveChunkDataState(state);
    switch (state.object.type)
    {
        inline else => |k|
        {
            const resultInfo = @typeInfo(ActionAndState);
            for (resultInfo.Union.fields) |f|
            {
                if (@field(ChunkType, f.name) == k)
                {
                    return @unionInit(ActionAndState, f.name, &.{
                        .action = @field(action, f.name),
                        .state = @field(state_, f.name),
                    });
                }
            }
        }
    }
}

pub fn getActiveChunkDataState(state: *const common.ChunkState) TaggedChunkDataStatePointer
{
    const chunkStateInfo = @typeInfo(@TypeOf(ChunkDataState.value));
    const taggedPointerInfo = @typeInfo(TaggedChunkDataStatePointer);
    for (taggedPointerInfo.Union.fields) |pointerField|
    {
        const pointerFieldInfo = @typeInfo(pointerField.type);
        const fieldType = pointerFieldInfo.Pointer.child;

        const found = found:
        {
            for (chunkStateInfo.Union.fields) |chunkStateField|
            {
                if (chunkStateField.type == fieldType)
                {
                    if (state.object.type == @field(ChunkType, pointerField.name))
                    {
                        const pointer = &@field(state.dataState, chunkStateField.name);
                        return @unionInit(TaggedChunkDataStatePointer, pointerField, pointer);
                    }
                    break :found true;
                }
            }
            break :found false;
        };

        if (!found)
        {
            return @unionInit(TaggedChunkDataStatePointer, pointerField, {});
        }
    }

    unreachable;
}

pub fn parseChunkData(context: *const common.Context) !bool
{
    const chunk = &context.state.chunk;
    const data = &chunk.object.data;
    const action = &chunk.dataState.action;

    try common.initStateForAction(context, {}, action);

    switch (getActiveChunkDataActionAndState(chunk))
    {
        .ImageHeader => |t|
        {
            const ihdr = &data.imageHeader;
            switch (t.actionKey())
            {
                .Width => 
                {
                    const value = try utils.readPngU32Dimension(context.sequence);
                    ihdr.width = value;
                    t.resetAction(.Height);
                },
                .Height =>
                {
                    const value = try utils.readPngU32Dimension(context.sequence);
                    ihdr.height = value;
                    t.resetAction(.BitDepth);
                },
                .BitDepth =>
                {
                    const value = try pipelines.removeFirst(context.sequence);
                    ihdr.bitDepth = value;
                    if (!isBitDepthValid(value))
                    {
                        return error.InvalidBitDepth;
                    }
                    t.resetAction(.ColorType);
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
                    t.resetAction(.CompressionMethod);
                },
                .CompressionMethod =>
                {
                    const value = try pipelines.removeFirst(context.sequence);
                    ihdr.compressionMethod = value;
                    if (!isCompressionMethodValid(value))
                    {
                        return error.InvalidCompressionMethod;
                    }
                    t.resetAction(.FilterMethod);
                },
                .FilterMethod =>
                {
                    const value = try pipelines.removeFirst(context.sequence);
                    ihdr.filterMethod = value;
                    if (!isFilterMethodValid(value))
                    {
                        return error.InvalidFilterMethod;
                    }
                    t.resetAction(.InterlaceMethod);
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
                    context.state.imageHeader = ihdr.*;
                    return true;
                },
            }
            return false;
        },
        .Palette => |t|
        {
            const plteNode = &data.palette;

            const functor = PaletteBytesProcessor
            {
                .context = context,
                .plteState = t.state,
                .plteNode = plteNode,
            };

            const done = try utils.removeAndProcessNextByte(
                context,
                &t.state.bytesRead,
                functor);

            if (done)
            {
                // This can be computed prior though.
                context.state.paletteLen = @intCast(plteNode.colors.items.len);
            }

            return done;
        },
        .ImageEnd =>
        {
            std.debug.assert(chunk.object.dataByteLen == 0);
            return true;
        },
        .ImageData => |t|
        {
            const imageData = &context.state.imageData;
            const bytesRead = &t.state.bytesRead;
            const bytesLeftToRead = chunk.object.dataByteLen - bytesRead.*;

            var sequence = context.sequence.*;
            const newLen = @min(sequence.len(), bytesLeftToRead);
            const isLastLoopForChunk = newLen == bytesLeftToRead;
            sequence = sequence.sliceToExclusive(sequence.getPosition(newLen));

            const carryOverData = &imageData.carryOverData;
            const usesCarryOverSegment = carryOverData.isActive();

            // TODO: Think of a better solution to this hijacking, it's just dirty.
            var carryOverFirstSegment: pipelines.Segment = undefined;
            // Start segment with updated slice and byte positions.
            var hijackedStartSegment: pipelines.Segment = undefined;
            if (usesCarryOverSegment)
            {
                carryOverFirstSegment = carryOverData.segment(@constCast(sequence.start().segment));

                const oldStart = sequence.start();
                hijackedStartSegment = oldStart.segment.*;
                hijackedStartSegment.data.bytePosition += oldStart.offset;
                // This is the key hijacking thing that I kind of hate.
                hijackedStartSegment.data.items = hijackedStartSegment.data.items[oldStart.offset ..];

                sequence.range.start = .{
                    .segment = &carryOverFirstSegment,
                    .offset = carryOverData.offset,
                };
                sequence.range.len += carryOverData.len();
            }

            defer
            {
                const maybeNewStart: ?pipelines.SequencePosition = newStart:
                {
                    if (!usesCarryOverSegment)
                    {
                        break :newStart sequence.start();
                    }

                    const notFullyReadCarryOverSegment = sequence.start().segment == &carryOverFirstSegment;
                    // Can only happen if we get an error, but we still have to update it.
                    if (notFullyReadCarryOverSegment)
                    {
                        carryOverData.offset = sequence.start().offset;
                        std.debug.assert(carryOverData.offset < carryOverFirstSegment.len());
                        break :newStart null;
                    }
                    else
                    {
                        carryOverData.setInactive();
                    }

                    if (sequence.start().segment != &hijackedStartSegment)
                    {
                        break :newStart sequence.start();
                    }

                    var oldStart = context.sequence.start();
                    // The offset on the hijacked segment is always zero, because it can't be the first.
                    // This has been mitigated by slicing the items.
                    // So the actual offset is the slice len difference + the new offset.
                    const arrayWasShiftedBy = oldStart.segment.len() - hijackedStartSegment.len();
                    oldStart.offset = sequence.start().offset + arrayWasShiftedBy;
                    std.debug.assert(oldStart.offset < oldStart.segment.len());
                    break :newStart oldStart;
                };

                if (maybeNewStart) |newStart|
                {
                    const lenChange = newLen - sequence.len();
                    bytesRead.* += @intCast(lenChange);
                    context.sequence.* = context.sequence.sliceFrom(newStart);
                }
            }

            const readContext = .{
                .allocator = context.allocator,
                .sequence = &sequence,
            };

            _ = utils.readZlibData(readContext, &imageData.zlib, &imageData.bytes)
                catch |err|
                {
                    if (err != error.NotEnoughBytes)
                    {
                        return err;
                    }

                    if (isLastLoopForChunk)
                    {
                        // Not implemented yet.
                        std.debug.assert(!usesCarryOverSegment);

                        if (sequence.len() == 0)
                        {
                            return true;
                        }

                        // Go over the remaining bytes and save them to the carry-over segment.
                        // Techincally, multiple separate carry-over segments are possible,
                        // but I'll ignore that possibility for now.
                        const carryOverBuffer = try carryOverData.array
                            .addManyAsSlice(context.allocator, sequence.len());
                        sequence.copyTo(carryOverBuffer);
                        carryOverData.offset = 0;
                        carryOverData.bytePosition = sequence.getStartBytePosition();
                        return true;
                    }

                    return error.NotEnoughBytes;
                };
            return isLastLoopForChunk and sequence.len() == 0;
        },
        .Transparency => |*t|
        {
            switch (chunk.object.data.transparency)
            {
                .paletteEntryAlphaValues => |*alphaValues|
                {
                    const bytesRead = &t.state.bytesRead;
                    const functor = TransparencyBytesProcessor
                    {
                        .alphaValues = alphaValues,
                        .allocator = context.allocator,
                    };

                    // const result = try utils.removeAndProcessAsManyBytesAsAvailable(context, bytesRead, functor);
                    const done = try utils.removeAndProcessNextByte(context, bytesRead, functor);
                    return done;
                },
                .gray => |*gray|
                {
                    gray.* = try pipelines.readNetworkUnsigned(context.sequence, u16);
                    return true;
                },
                .rgb => |*rgb|
                {
                    const rgbIndex = t.actionKey().RGB;

                    const value = try pipelines.readNetworkUnsigned(context.sequence, u16);
                    rgb.at(@intFromEnum(rgbIndex)).* = value;

                    if (rgbIndex.next()) |next|
                    {
                        t.resetAction(.{
                            .RGB = next,
                        });
                        return false;
                    }
                    return true;
                },
            }
        },
        .Gamma =>
        {
            // The spec doesn't say anything about this value being limited.
            data.gamma = try pipelines.readNetworkUnsigned(context.sequence, u32);
            return true;
        },
        .PrimaryChrom => |chromState|
        {
            const primaryChroms = &data.primaryChroms;
            const value = try pipelines.readNetworkUnsigned(context.sequence, u32);

            const vector = chromState.vector();
            const index = chromState.coord();
            const targetPointer = &primaryChroms.values[vector].values[index];
            targetPointer.* = value;

            chromState.advance();

            const done = chromState.done();
            return done;
        },
        .ColorSpace =>
        {
            const value = try pipelines.removeFirst(context.sequence);
            const e: RenderingIntent = @enumFromInt(value);
            data.renderingIntent = e;
            if (!e.isValid())
            {
                return error.InvalidRenderingIntent;
            }
            return true;
        },
        .ICCProfile => |state|
        {
            const node = &data.iccProfile;

            switch (state.action)
            {
                .ProfileName =>
                {
                    const maxNameLen = 80;
                    try utils.readNullTerminatedText(context, &node.name, maxNameLen);
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
                    const isDone = try utils.readZlibData(context, &state.zlib, &node.decompressedProfile);
                    return isDone;
                },
            }
        },
        .Text => |state|
        {
            const node = &data.text;
            switch (state.action)
            {
                .Keyword =>
                {
                    try utils.readKeywordText(context, &node.keyword, &state.bytesRead);
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

                    const done = try utils.removeAndProcessAsManyBytesAsAvailable(context, bytesRead, functor);
                    return done;
                },
            }
        },
        .CompressedText => |state|
        {
            const node = &data.text;
            switch (state.action)
            {
                .Keyword =>
                {
                    try utils.readKeywordText(context, &node.keyword, &state.bytesRead);
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
                    const isDone = try utils.readZlibData(context, &state.zlib, &node.text);
                    return isDone;
                },
            }

        },
        // Let's just skip for now.
        else => return try utils.skipBytes(context, chunk),
    }
}
