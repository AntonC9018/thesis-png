const common = @import("common.zig");
const std = common.std;
const pipelines = common.pipelines;
const zlib = common.zlib;
const utils = common.utils;
const Context = common.Context;

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

pub const RGB16 = GenericRGB(u16);

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
    action: ChunkDataAction,
    value: union
    {
        none: void,
        bytesSkipped: u32,
        palette: PaletteState,
        transparency: TransparencyState,
        primaryChroms: PrimaryChroms,
        iccProfile: ICCProfileState,
        text: TextState,
        compressedText: CompressedTextState,
    },
};

pub const TaggedChunkDataAction = union(ChunkType)
{
    ImageHeader: *ImageHeaderAction,
    Palette: void,
    ImageData: void, // Only Zlib
    ImageEnd: void, // No bytes

    Transparency: *TransparencyAction, // Only RGB
    Gamma: void, // Only value
    PrimaryChrom: *PrimaryChromAction,
    ColorSpace: void, // Only rendering intent
    ICCProfile: *ICCProfileAction,

    Text: *TextAction,
    CompressedText: *CompressedTextAction,
    InternationalText: void, // TODO:

    // TODO:
    Background: void,
    PhysicalPixelDimensions: *PhysicalPixedDimensionsAction,
    SignificantBits: void,
    SuggestedPalette: void,
    PaletteHistogram: void,
    LastModificationTime: void,
};

pub const ChunkDataAction: type = b:
{
    var info = @typeInfo(TaggedChunkDataAction);
    const oldFields = info.Union.fields;
    var fields = oldFields[0 .. oldFields.len].*;
    for (&fields) |*field|
    {
        field.type = newType:
        {
            const pointerOrVoid = field.type;
            if (pointerOrVoid == void)
            {
                break :newType void;
            }
            const pointerInfo = @typeInfo(pointerOrVoid);
            break :newType pointerInfo.Pointer.child;
        };
    }
    info.Union.tag_type = null;
    info.Union.decls = &.{};
    info.Union.fields = &fields;
    break :b @Type(info);
};

pub const TaggedChunkDataStatePointer = union(ChunkType)
{
    ImageHeader: void,
    Palette: *PaletteState,
    ImageData: void,
    ImageEnd: void,

    Transparency: *TransparencyState,
    Gamma: void,
    PrimaryChrom: *PrimaryChroms,
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
};

pub fn ActionAndState(Action: type, State: type) type
{
    return struct
    {
        action: Action,
        state: State,
    };
}

pub const PhysicalPixedDimensionsAction = enum
{
    PixelPerUnitX,
    PixelPerUnitY,
    UnitSpecifier,
};

pub const PixelUnitSpecifier = enum(u8)
{
    Unknown = 0,
    Meter = 1,
};

const TransparencyAction = union(enum)
{
    RGB: RGBAction,
    none: void,
};

// Not generated with reflection, for better LSP experience.
const TaggedNodeDataActionAndState = union(ChunkType)
{
    ImageHeader: ActionAndState(*ImageHeaderAction, void),
    Palette: ActionAndState(void, *PaletteState), // Only RGB
    ImageData: ActionAndState(void, void),
    ImageEnd: ActionAndState(void, void), // No bytes

    Transparency: ActionAndState(*TransparencyAction, *TransparencyState), // Only RGB
    Gamma: ActionAndState(void, void), // Only value
    PrimaryChrom: ActionAndState(*PrimaryChromAction, *PrimaryChroms),
    ColorSpace: ActionAndState(void, void), // Only rendering intent
    ICCProfile: ActionAndState(*ICCProfileAction, *ICCProfileState),

    Text: ActionAndState(*TextAction, *TextState),
    CompressedText: ActionAndState(*CompressedTextAction, *CompressedTextState),
    InternationalText: ActionAndState(void, void), // TODO:

    // TODO:
    Background: ActionAndState(void, void),
    PhysicalPixelDimensions: ActionAndState(*PhysicalPixedDimensionsAction, void),
    SignificantBits: ActionAndState(void, void),
    SuggestedPalette: ActionAndState(void, void),
    PaletteHistogram: ActionAndState(void, void),
    LastModificationTime: ActionAndState(void, void),

    pub fn hasAction(self: *const TaggedNodeDataActionAndState) bool
    {
        switch (self)
        {
            inline else => |x|
            {
                if (@TypeOf(x.action) == void)
                {
                    return false;
                }
                if (@hasDecl(x.action, "none"))
                {
                    return x.action != .none;
                }
                return true;
            }
        }
    }
};

pub const CompressedTextAction = enum
{
    Keyword,
    CompressionMethod,
    Text,
};

pub const CompressedTextState = struct
{
    zlib: zlib.State,
    buffer: std.ArrayListUnmanaged(u8) = .{},
};

pub const TextAction = enum
{
    Keyword,
    Text,
};

pub const TextState = struct
{
    buffer: std.ArrayListUnmanaged(u8) = .{},
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


pub const TransparencyState = union(TransparencyKind)
{
    IndexedColor: void,
    Grayscale: void,
    TrueColor: RGB16,
};

pub const PrimaryChromAction = struct
{
    value: u8,

    pub fn vector(self: PrimaryChromAction) u8
    {
        return self.value / 2;
    }
    pub fn coord(self: PrimaryChromAction) u8
    {
        return self.value % 2;
    }
    pub fn done(self: PrimaryChromAction) bool
    {
        return self.value == 8;
    }
    pub fn advance(self: *PrimaryChromAction) void
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
};

pub const PaletteState = struct
{
    rgbAction: RGBAction,
    // Needed to produce the color node.
    color: RGB,
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

const KnownChunkType = common.ExhaustiveVariant(ChunkType);

fn asKnown(chunkType: ChunkType) KnownChunkType
{
    return common.exhaustive(chunkType);
}


fn isKnownChunkType(chunkType: ChunkType) bool
{
    _ = std.meta.intToEnum(KnownChunkType, @intFromEnum(chunkType))
        catch return false;
    return true;
}


fn ActionType(comptime chunkType: anytype) type
{
    const result = @TypeOf(
        @field(@as(ChunkDataAction, undefined),
            @tagName(chunkType)));
    return result;
}

fn StateType(comptime chunkType: KnownChunkType) type
{
    const fieldName = getChunkDataFieldName(chunkType)
        orelse return void;
    return @TypeOf(@field(@as(ChunkDataState, undefined).value, fieldName));
}

fn setChunkDataAction(
    data: *ChunkDataState,
    comptime chunkType: KnownChunkType,
    value: ActionType(chunkType)) void
{
    const actionFieldName = @tagName(chunkType);
    data.action = @unionInit(@TypeOf(data.action), actionFieldName, value);
}

fn setChunkData(
    data: *ChunkDataState,
    comptime chunkType: KnownChunkType,
    value: StateType(chunkType)) void
{
    const name = comptime getChunkDataFieldName(chunkType) orelse {
        @compileLog(chunkType);
        unreachable;
    };
    data.value = @unionInit(@TypeOf(data.value), name, value);
}

// TODO:
// Check if the size specified matches the expected size.
// If the size of the chunk is dynamic, resize
// the sequence appropriately and reinterpret error.NotEnoughBytes.
pub fn initChunkDataNode(context: *Context, chunkType: ChunkType) !void
{
    const chunk = &context.state.chunk;
    const dataState = &chunk.dataState;

    if (!isKnownChunkType(chunkType))
    {
        chunk.object.isKnownType = false;
        dataState.* = undefined;
        return;
    }

    chunk.object.isKnownType = true;

    // Initialize the data state
    switch (asKnown(chunkType))
    {
        .Transparency =>
        {
            const kind: TransparencyKind = switch (context.state.imageHeader.?.colorType.flags)
            {
                ColorType.ColorUsed | ColorType.PalleteUsed => .IndexedColor,
                0 => .Grayscale,
                ColorType.ColorUsed => .TrueColor,
                else => return error.BadColorTypeForTransparencyChunk,
            };
            const state: TransparencyState = switch (kind)
            {
                .TrueColor => .{ .TrueColor = std.mem.zeroes(RGB16) },
                inline else => |k| k,
            };
            setChunkData(dataState, .Transparency, state);
            setChunkDataAction(dataState, .Transparency, switch (kind)
            {
                .IndexedColor => .{ .RGB = .R },
                else => .none,
            });
        },
        .ImageHeader =>
        {
            context.state.imageHeader = std.mem.zeroes(ImageHeader);
            dataState.action = .{ .ImageHeader = .Width };
            dataState.value = undefined;
        },
        inline
        .ImageData,
        .ImageEnd,
        .Gamma,
        .PrimaryChrom,
        .ColorSpace,
        .InternationalText,
        .Background,
        .PhysicalPixelDimensions,
        .SignificantBits,
        .SuggestedPalette,
        .PaletteHistogram,
        .LastModificationTime => |t|
        {
            setChunkDataAction(dataState, t, std.mem.zeroes(ActionType(t)));
            dataState.value = undefined;
            std.debug.print("Set the initial action to {}\n", .{std.mem.zeroes(ActionType(t))});
        },
        inline
        .ICCProfile,
        .CompressedText => |t|
        {
            setChunkData(dataState, t, .{
                .zlib = .{}
            });
            setChunkDataAction(dataState, t, std.mem.zeroes(ActionType(t)));
        },
        inline else => |t|
        {
            setChunkData(dataState, t, std.mem.zeroes(StateType(t)));
            setChunkDataAction(dataState, t, std.mem.zeroes(ActionType(t)));
        },
    }

    // Validate preconditions
    switch (getActiveChunkDataState(dataState, asKnown(chunkType)))
    {
        .Palette =>
        {
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
            context.state.paletteLen = numColors;
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
        },
        .ImageData =>
        {
            if (!context.state.isData)
            {
                context.state.isData = true;
            }
        },
        .Transparency => |s|
        {
            const len = chunk.object.dataByteLen;
            switch (s.*)
            {
                .IndexedColor =>
                {
                    if (context.state.paletteLen == null)
                    {
                        return error.TransparencyWithoutPalette;
                    }

                    const maxLength = context.state.paletteLen.?;
                    if (len > maxLength)
                    {
                        return error.TransparencyLengthExceedsPalette;
                    }
                },
                .Grayscale =>
                {
                    if (len != 2)
                    {
                        return error.GrayscaleTransparencyLengthMustBe2;
                    }
                },
                .TrueColor =>
                {
                    if (len != 3 * 2)
                    {
                        return error.TrueColorTransparencyLengthMustBe6;
                    }
                },
            }
        },
        else => {},
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
    primaryChrom: PrimaryChromAction,
    iccProfile: ICCProfileState,
    text: TextState,
    compressedText: CompressedTextState,
};

fn readRgbComponentNode(
    context: *Context,
    action: *RGBAction,
    color: *RGB,
    byte: u8) !bool
{
    {
        try context.level().pushNode(.{
            .RGBComponent = action.*,
        });
        defer context.level().pop();

        const colorByte = colorByte:
        {
            switch (action.*)
            {
                .R => break :colorByte &color.r,
                .G => break :colorByte &color.g,
                .B => break :colorByte &color.b,
            }
        };
        colorByte.* = byte; 

        try context.level().completeNodeWithValue(.{
            .Number = byte,
        });
    }

    if (action.next()) |next|
    {
        action.* = next;
        return false;
    }
    else
    {
        action.* = RGBAction.FirstColor;
        return true;
    }
}

const PaletteBytesProcessor = struct
{
    context: *Context,
    state: *PaletteState,

    pub fn each(self: *const PaletteBytesProcessor, byte: u8) !void
    {
        const action = &self.state.rgbAction;

        try self.context.level().pushNode(.RGBColor);
        defer self.context.level().pop();

        const color = &self.state.color;
        const readFully = try readRgbComponentNode(
            self.context,
            action,
            color,
            byte);
        
        if (readFully)
        {
            try self.context.level().completeNodeWithValue(.{
                .RGB = color.*,
            });
        }
    }
};

const TransparencyBytesProcessor = struct
{
    context: *Context,
    allocator: std.mem.Allocator,

    pub fn each(self: *const TransparencyBytesProcessor, byte: u8) !void
    {
        // TODO: needs to be done BEFORE reading.
        try self.context.level().push();
        defer self.context.level().pop();

        try self.context.level().completeNodeWithValue(.{
            .Number = byte,
        });
    }
};

const TextBytesProcessor = struct
{
    text: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn initCount(self: *const TextBytesProcessor, count: usize) !void
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

pub fn getActiveDataAction(state: *common.ChunkState) TaggedChunkDataAction
{
    switch (common.exhaustive(state.object.type))
    {
        inline else => |key|
        {
            const fieldName = @tagName(key);
            const value = if (ActionType(key) == void) 
                    {}
                else
                    &@field(state.dataState.action, fieldName);
            return @unionInit(TaggedChunkDataAction, fieldName, value);
        }
    }
}

pub fn getActiveChunkDataActionAndState(state: *common.ChunkState) TaggedNodeDataActionAndState
{
    const action = getActiveDataAction(state);
    const state_ = getActiveChunkDataState(&state.dataState, asKnown(state.object.type));
    switch (common.exhaustive(state.object.type))
    {
        inline else => |k|
        {
            const name = @tagName(k);
            return @unionInit(TaggedNodeDataActionAndState, name, .{
                .action = @field(action, name),
                .state = @field(state_, name),
            });
        },
    }
}

// The structure is not pretty, I supposed I should have made the union look the same.
pub fn getChunkDataFieldName(comptime chunkType: KnownChunkType) ?[:0]const u8
{
    const chunkStateInfo = comptime @typeInfo(@TypeOf(@as(ChunkDataState, undefined).value));
    switch (chunkType)
    {
        inline else => |k|
        {
            const fieldName = @tagName(k);
            const fieldPointerType = @TypeOf(@field(@as(TaggedChunkDataStatePointer, undefined), fieldName));

            const dataFieldName: ?[:0]const u8 = comptime dataFieldName:
            {
                if (fieldPointerType == void)
                {
                    break :dataFieldName null;
                }

                const fieldTypeInfo = @typeInfo(fieldPointerType);
                const fieldType = fieldTypeInfo.Pointer.child;

                for (chunkStateInfo.Union.fields) |chunkStateField|
                {
                    if (chunkStateField.type == fieldType)
                    {
                        break :dataFieldName chunkStateField.name;
                    }
                }
                break :dataFieldName null;
            };

            return dataFieldName;
        }
    }
}

pub fn getActiveChunkDataState(state: *ChunkDataState, chunkType: KnownChunkType) TaggedChunkDataStatePointer
{
    switch (chunkType)
    {
        inline else => |t|
        {
            const dataFieldName = comptime getChunkDataFieldName(t);

            if (dataFieldName) |dataFieldName_|
            {
                const data = &@field(state.value, dataFieldName_);
                return @unionInit(TaggedChunkDataStatePointer, @tagName(t), data);
            }
            else
            {
                return @unionInit(TaggedChunkDataStatePointer, @tagName(t), {});
            }
        }
    }
}

const ast = common.ast;

fn parseImageData(context: *Context) !bool
{
    const imageData = &context.state.imageData;

    var sequence = context.sequence().*;
    const carryOverData = &imageData.carryOverData;
    const usesCarryOverSegment = carryOverData.isActive();

    var segments: ?struct
        {
            carryOverFirst: pipelines.Segment,
            hijackedStart: pipelines.Segment,
        } = segments:
    {
        if (!usesCarryOverSegment)
        {
            break :segments null;
        }

        const replacedStart = sequence.start();
        var hijackedStartSegment = replacedStart.segment.*;
        // This is a hack that applies the sequence position offset to a segment's buffer.
        // Because we can't have intermediate segments have an offset buffer.
        hijackedStartSegment.data.bytePosition += replacedStart.offset;
        // This is the key hijacking thing that I kind of hate.
        hijackedStartSegment.data.items = hijackedStartSegment.data.items[replacedStart.offset ..];

        break :segments .{
            .carryOverFirst = undefined,
            .hijackedStart = hijackedStartSegment,
        };
    };

    if (segments) |*s|
    {
        // TODO: Think of a better solution to this hijacking, it's just dirty.
        // NOTE: Since this references its own memory, it has to be done separately after creation.
        s.carryOverFirst = carryOverData.segment(&s.hijackedStart);

        sequence.range.start = .{
            .segment = &s.carryOverFirst,
            .offset = carryOverData.offset,
        };
        sequence.range.len += carryOverData.len();
    }

    defer
    {
        const maybeNewStart: ?pipelines.SequencePosition = newStart:
        {
            if (segments == null)
            {
                break :newStart sequence.start();
            }

            const s = &segments.?;

            {
                // Can only happen if we get an error, but we still have to update it.
                const notFullyReadCarryOverSegment = sequence.start().segment == &s.carryOverFirst;
                if (notFullyReadCarryOverSegment)
                {
                    carryOverData.offset = sequence.start().offset;
                    std.debug.assert(carryOverData.offset < s.carryOverFirst.len());
                    break :newStart null;
                }
                else
                {
                    carryOverData.setInactive();
                }
            }

            if (sequence.start().segment != &s.hijackedStart)
            {
                break :newStart sequence.start();
            }

            var oldStart = context.sequence().start();
            // The offset on the hijacked segment is always zero, because it can't be the first.
            // This has been mitigated by slicing the items.
            oldStart.offset += sequence.start().offset;
            std.debug.assert(oldStart.offset < oldStart.segment.len());
            break :newStart oldStart;
        };

        if (maybeNewStart) |newStart|
        {
            context.sequence().* = context.sequence().sliceFrom(newStart);
        }
    }

    var readContext = readContext:
    {
        var c = context.*;
        c.common.sequence = &sequence;
        break :readContext c;
    };

    // This creates syntactic nodes, along with the data nodes.
    // What we have to do besides this, is that we have to complete 
    // the created nodes if we're going to be doing a carry over.
    // So we need to go on a level below, call complete,
    // then save the semantic node id there, and then have it be passed rather than created inside.
    // So, the outside has to have a mechanism to override what happens on the inside.
    // Specifically, setting a semantic id for a node to be created,
    // and then having the create code actually check that first.
    // But in that case, make sure it's empty first.
    _ = utils.readZlibData(&readContext, &imageData.zlib, &imageData.bytes)
        catch |err|
        {
            if (err != error.NotEnoughBytes)
            {
                return err;
            }

            if (!context.isLastChunkSequenceSlice)
            {
                return error.NotEnoughBytes;
            }

            // Double carry overs are not implemented yet.
            std.debug.assert(!usesCarryOverSegment);


            {
                try context.level().captureSemanticContextForHierarchy(&imageData.zlibStreamSemanticContext);
            }

            {
                if (sequence.len() == 0)
                {
                    return true;
                }

                // Go over the remaining bytes and save them to the carry-over segment.
                // Technically, multiple separate carry-over segments are possible,
                // but I'll ignore that possibility for now.
                const carryOverBuffer = try carryOverData.array
                    .addManyAsSlice(context.allocator(), sequence.len());
                sequence.copyTo(carryOverBuffer);
                carryOverData.offset = 0;
                carryOverData.bytePosition = sequence.getStartBytePosition();
            }

            return true;
        };

    return context.isLastChunkSequenceSlice and sequence.len() == 0;
}

pub fn parseChunkData(context: *Context) !bool
{
    const activeActionAndState = activeActionAndState:
    {
        const chunk = &context.state.chunk;
        if (!chunk.object.isKnownType)
        {
            const s = context.sequence();
            s.* = s.sliceFrom(s.end());
            return context.isLastChunkSequenceSlice;
        }
        const activeActionAndState = getActiveChunkDataActionAndState(chunk);
        break :activeActionAndState activeActionAndState;
    };

    switch (activeActionAndState)
    {
        .ImageHeader => |t|
        {
            // We could map this automatically, but then we'd also want to defer pop conditionally.
            // I probably don't want that? Though it's not that bad.
            try context.level().pushNode(.{ 
                .ImageHeader = t.action.*,
            });
            defer context.level().pop();

            // We have to save that for error checking.
            const ihdr = &context.state.imageHeader.?;

            switch (t.action.*)
            {
                // The structure is the same on these and could be abstracted.
                // 1. read
                // 2. (optional) convert
                // 3. save data for future validation
                // 4. update the action
                // 5. set the node value
                // 6. do validation
                .Width => 
                {
                    const value = try utils.readPngU32Dimension(context.sequence());

                    ihdr.width = value;
                    t.action.* = .Height;

                    try context.level().completeNodeWithValue(.{
                        .Number = value,
                    });
                },
                .Height =>
                {
                    const value = try utils.readPngU32Dimension(context.sequence());

                    ihdr.height = value;
                    t.action.* = .BitDepth;

                    try context.level().completeNodeWithValue(.{
                        .Number = value,
                    });
                },
                .BitDepth =>
                {
                    const value = try pipelines.removeFirst(context.sequence());

                    ihdr.bitDepth = value;
                    t.action.* = .ColorType;

                    try context.level().completeNodeWithValue(.{
                        .Number = value,
                    });

                    if (!isBitDepthValid(value))
                    {
                        return error.InvalidBitDepth;
                    }
                },
                .ColorType =>
                {
                    const value = try pipelines.removeFirst(context.sequence());

                    const colorType = .{ .flags = value };
                    ihdr.colorType = colorType;

                    t.action.* = .CompressionMethod;

                    try context.level().completeNodeWithValue(.{
                        .ColorType = colorType,
                    });

                    if (!isColorTypeValid(ihdr.colorType))
                    {
                        return error.InvalidColorType;
                    }
                    if (!isColorTypeAllowedForBitDepth(ihdr.bitDepth, ihdr.colorType))
                    {
                        return error.ColorTypeNotAllowedForBitDepth;
                    }
                },
                .CompressionMethod =>
                {
                    const value = try pipelines.removeFirst(context.sequence());

                    const compressionMethod = value;
                    ihdr.compressionMethod = compressionMethod;

                    t.action.* = .FilterMethod;

                    try context.level().completeNodeWithValue(.{
                        .CompressionMethod = compressionMethod,
                    });

                    if (!isCompressionMethodValid(value))
                    {
                        return error.InvalidCompressionMethod;
                    }

                },
                .FilterMethod =>
                {
                    const value = try pipelines.removeFirst(context.sequence());

                    const filterMethod = value;
                    ihdr.filterMethod = filterMethod;

                    t.action.* = .InterlaceMethod;

                    try context.level().completeNodeWithValue(.{
                        .FilterMethod = filterMethod,
                    });

                    if (!isFilterMethodValid(value))
                    {
                        return error.InvalidFilterMethod;
                    }
                },
                .InterlaceMethod =>
                {
                    const value = try pipelines.removeFirst(context.sequence());

                    const enumValue: InterlaceMethod = @enumFromInt(value);
                    ihdr.interlaceMethod = enumValue;

                    try context.level().completeNodeWithValue(.{
                        .InterlaceMethod = enumValue,
                    });

                    switch (enumValue)
                    {
                        .None, .Adam7 => {},
                        _ => return error.InvalidInterlaceMethod,
                    }
                    return true;
                },
            }
            return false;
        },
        .Palette => |t|
        {
            const functor = PaletteBytesProcessor
            {
                .context = context,
                .state = t.state,
            };

            const done = try utils.removeAndProcessNextByte(context, functor);
            return done;
        },
        .ImageEnd =>
        {
            std.debug.assert(context.sequence().len() == 0);
            return true;
        },
        .ImageData =>
        {
            try context.level().pushInit(struct
            {
                context_: *Context,

                pub fn execute(self: @This()) !void
                {
                    const imageData = &self.context_.state.imageData;
                    try self.context_.level()
                        .applySemanticContextForHierarchy(imageData.zlibStreamSemanticContext);
                }
            }{
                .context_ = context,
            });
            defer context.level().pop();

            const done = try parseImageData(context);
            if (done)
            {
                try context.level().completeNode();
            }

            return done;
        },
        .Transparency => |t|
        {
            // TODO: Figure out how the nodes should be.
            switch (t.state.*)
            {
                .IndexedColor =>
                {
                    const functor = TransparencyBytesProcessor
                    {
                        .context = context,
                        .allocator = context.allocator(),
                    };

                    const done = try utils.removeAndProcessNextByte(context, functor);
                    return done;
                },
                .Grayscale =>
                {
                    const value = try pipelines.readNetworkUnsigned(context.sequence(), u16);
                    try context.level().completeNodeWithValue(.{
                        .Number = value,
                    });

                    return true;
                },
                .TrueColor => |*rgb|
                {
                    try context.level().pushNode(.RGBColor);
                    defer context.level().pop();

                    const rgbIndex = &t.action.RGB;
                    {
                        try context.level().pushNode(.{ .RGBComponent = rgbIndex.* });
                        defer context.level().pop();

                        const value = try pipelines.readNetworkUnsigned(context.sequence(), u16);
                        rgb.at(@intFromEnum(rgbIndex.*)).* = value;

                        try context.level().completeNodeWithValue(.{
                            .Number = value,
                        });
                    }

                    if (rgbIndex.next()) |next|
                    {
                        rgbIndex.* = next;
                        return false;
                    }
                    else
                    {
                        try context.level().completeNodeWithValue(.{
                            .RGB16 = rgb.*,
                        });
                        return true;
                    }
                },
            }
        },
        .Gamma =>
        {
            // The spec doesn't say anything about this value being limited,
            // which is why the regular "read unsigned" function is used, and not the
            // specialized png one.
            const gamma = try pipelines.readNetworkUnsigned(context.sequence(), u32);

            // Completes the node on the level above.
            try context.level().completeNodeWithValue(.{
                .U32 = gamma,
            });

            return true;
        },
        .PrimaryChrom => |t|
        {
            try context.level().pushNode(.{
                .PrimaryChrom = t.action.*,
            });
            defer context.level().pop();

            const value = try pipelines.readNetworkUnsigned(context.sequence(), u32);

            // This is probably not needed. We probably don't want to save this.
            const vector = t.action.vector();
            const index = t.action.coord();
            const targetPointer = &t.state.values[vector].values[index];
            targetPointer.* = value;

            t.action.advance();

            try context.level().completeNodeWithValue(.{
                .U32 = value,
            });

            const done = t.action.done();
            return done;
        },
        .ColorSpace =>
        {
            try context.level().pushNode(.RenderingIntent);
            defer context.level().pop();

            const value = try pipelines.removeFirst(context.sequence());

            const e: RenderingIntent = @enumFromInt(value);
            try context.level().completeNodeWithValue(.{
                .RenderingIntent = e,
            });

            if (!e.isValid())
            {
                return error.InvalidRenderingIntent;
            }
            return true;
        },
        .ICCProfile => |t|
        {
            switch (t.action.*)
            {
                .ProfileName =>
                {
                    const maxNameLen = 80;
                    const name = &t.state.bytes;
                    try utils.readNullTerminatedText(context, name, maxNameLen);

                    t.action.* = .CompressionMethod;

                    try context.level().completeNodeWithValue(.{
                        .OwnedString = common.move(name),
                    });
                    
                    return false;
                },
                .CompressionMethod =>
                {
                    const compressionMethod = try pipelines.removeFirst(context.sequence());
                    try context.level().completeNodeWithValue(.{
                        .CompressionMethod = compressionMethod,
                    });

                    if (compressionMethod != 0)
                    {
                        return error.InvalidCompressionMethod;
                    }
                    return false;
                },
                .CompressedData =>
                {
                    const decompressedBuffer = &t.state.bytes;
                    const isDone = try utils.readZlibData(context, &t.state.zlib, decompressedBuffer);
                    // TODO:
                    // Make higher level nodes that represent structure in the decoded buffer.
                    // Currently since it's a string it's easy enough.
                    if (isDone)
                    {
                        try context.level().completeNodeWithValue(.{
                            .OwnedString = common.move(decompressedBuffer),
                        });
                    }
                    return isDone;
                },
            }
        },
        .Text => |t|
        {
            try context.level().pushNode(.{
                .TextAction = t.action.*,
            });
            defer context.level().pop();

            switch (t.action.*)
            {
                .Keyword =>
                {
                    const keyword = &t.state.buffer;
                    try utils.readKeywordText(context, keyword);

                    t.action.* = .Text;

                    try context.level().completeNodeWithValue(.{
                        .OwnedString = common.move(keyword),
                    });

                    return false;
                },
                .Text =>
                {
                    const buffer = &t.state.buffer;

                    const functor = TextBytesProcessor
                    {
                        .text = buffer,
                        .allocator = context.allocator(),
                    };

                    const done = try utils.removeAndProcessAsManyBytesAsAvailable(context, functor);
                    if (done)
                    {
                        try context.level().completeNodeWithValue(.{
                            .OwnedString = common.move(buffer),
                        });
                    }
                    return done;
                },
            }
        },
        .CompressedText => |t|
        {
            try context.level().pushNode(.{
                .CompressedText = t.action.*,
            });
            defer context.level().pop();

            switch (t.action.*)
            {
                .Keyword =>
                {
                    const keyword = &t.state.buffer;
                    try utils.readKeywordText(context, keyword);

                    t.action.* = .CompressionMethod;

                    try context.level().completeNodeWithValue(.{
                        .OwnedString = common.move(keyword),
                    });
                    return false;
                },
                .CompressionMethod =>
                {
                    const value = try pipelines.removeFirst(context.sequence());
                    t.action.* = .Text;

                    try context.level().completeNodeWithValue(.{
                        .CompressionMethod = value,
                    });

                    if (value != 0)
                    {
                        return error.UnsupportedCompressionMethod;
                    }
                    return false;
                },
                .Text =>
                {
                    const buffer = &t.state.buffer;
                    const isDone = try utils.readZlibData(context, &t.state.zlib, buffer);
                    if (isDone)
                    {
                        try context.level().completeNodeWithValue(.{
                            .OwnedString = common.move(buffer),
                        });
                    }
                    return isDone;
                },
            }

        },
        .PhysicalPixelDimensions => |t|
        {
            try context.level().pushNode(.{
                .PhysicalPixelDimensions = t.action.*,
            });
            defer context.level().pop();

            switch (t.action.*)
            {
                .PixelPerUnitX =>
                {
                    const value = try pipelines.readNetworkUnsigned(context.sequence(), u32);
                    try context.level().completeNodeWithValue(.{
                        .Number = value,
                    });
                    t.action.* = .PixelPerUnitY;
                    return false;
                },
                .PixelPerUnitY =>
                {
                    const value = try pipelines.readNetworkUnsigned(context.sequence(), u32);
                    try context.level().completeNodeWithValue(.{
                        .Number = value,
                    });
                    t.action.* = .UnitSpecifier;
                    return false;
                },
                .UnitSpecifier =>
                {
                    const value = try pipelines.removeFirst(context.sequence());
                    if (value != 0 and value != 1)
                    {
                        try context.level().completeNodeWithValue(.{
                            .Number = value,
                        });
                        return error.UnkownUnitSpecifier;
                    }
                    const unitSpecifier: PixelUnitSpecifier = @enumFromInt(value);

                    try context.level().completeNodeWithValue(.{
                        .PixelUnitSpecifier = unitSpecifier,
                    });
                    return true;
                },
            }
        },
        else => 
        {
            unreachable;
        },
    }
}
