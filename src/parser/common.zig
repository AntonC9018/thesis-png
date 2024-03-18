pub const std = @import("std");
pub const pipelines = @import("../pipelines.zig");
pub const zlib = @import("../zlib/zlib.zig");
pub const chunks = @import("chunks.zig");
pub const utils = @import("utils.zig");
pub const Settings = @import("../shared/Settings.zig");

// What is the next expected type?
pub const Action = enum
{
    Signature,
    Chunk,
};

pub const ChunkAction = enum 
{
    // Length of the data field.
    Length,
    ChunkType,
    Data,
    CyclicRedundancyCheck,
};

pub const State = struct
{
    levelInitMask: LevelInitMask,
    chunk: ChunkState,
    action: Action = .Signature,

    imageHeader: ?chunks.ImageHeader = null,
    // True after the IEND chunk has been parsed.
    isEnd: bool = false,
    // True after the first IDAT chunk data start being parsed.
    isData: bool = false,
    paletteLen: ?u32 = null,

    imageData: ImageData = .{},
};

pub fn isParserStateTerminal(state: *const State) bool 
{
    return state.action == .Chunk 
        and !state.levelInitMask.isInitedAtLevel(0);
}

pub const Context = struct
{
    state: *State,
    sequence: *pipelines.Sequence,
    allocator: std.mem.Allocator,
    settings: *const Settings,
    level: LevelContext,
};

pub const CarryOverSegment = struct
{
    array: std.ArrayListUnmanaged(u8) = .{},
    bytePosition: usize = 0,
    offset: u32 = 0,

    pub fn len(self: *const CarryOverSegment) u32
    {
        return @intCast(self.array.items.len - self.offset);
    }

    pub fn segment(self: *const CarryOverSegment, next: *pipelines.Segment) pipelines.Segment
    {
        return .{
            .data = .{
                .items = self.array.items,
                .capacity = self.array.capacity,
                .bytePosition = self.bytePosition,
            },
            .nextSegment = next,
        };
    }

    pub fn isActive(self: *const CarryOverSegment) bool
    {
        return self.array.items.len > 0;
    }

    pub fn setInactive(self: *CarryOverSegment) void
    {
        self.array.clearRetainingCapacity();
    }
};

// Of course, this will need to be reworked once I do the tree range optimizations
pub const ImageData = struct
{
    // Just read the raw bytes for now
    bytes: std.ArrayListUnmanaged(u8) = .{},
    zlib: zlib.State = .{},
    carryOverData: CarryOverSegment = .{},
};

pub const CyclicRedundancyCheck = struct
{
    value: u32,
};

pub const Chunk = struct
{
    dataByteLen: u32,
    type: chunks.ChunkType,
    data: chunks.ChunkData,
    crc: CyclicRedundancyCheck,
};

pub const ChunkState = struct
{
    action: ChunkAction = .Length,
    object: Chunk,
    dataState: chunks.ChunkDataState,
};

pub const LevelInitMask = struct
{
    mask: std.bit_set.IntegerBitSet(32) = .{ .mask = ~@as(0, u32) },

    pub fn setDeinitedAtLevel(self: *LevelInitMask, level: u5) void
    {
        self.mask.unset(level);
    }

    pub fn isInitedAtLevel(self: *const LevelInitMask, level: u5) void
    {
        return self.mask.isSet(level);
    }
};

pub const LevelContext = struct
{
    current: u5,
    max: u5,

    pub fn push(self: *LevelContext) void
    {
        self.current += 1;
        self.max = @max(self.current, self.max);
    }

    pub fn pop(self: *LevelContext) void
    {
        self.current -= 1;
    }

    pub fn assertPopped(self: *const LevelContext) void
    {
        std.debug.assert(self.current == 0);
    }
};

fn PointedToType(t: type) type
{
    const info = @typeInfo(t);
    return info.Pointer.child;
}

pub fn deinitCurrentLevel(context: *const Context) void
{
    const level = context.level.current;
    context.state.levelInitMask.setDeinitedAtLevel(level);
}

pub fn advanceAction(
    context: *const Context,
    action: anytype,
    value: PointedToType(@TypeOf(action))) void
{
    const level = context.level.current;
    context.state.levelInitMask.setDeinitedAtLevel(level);
    action.* = value;
}
