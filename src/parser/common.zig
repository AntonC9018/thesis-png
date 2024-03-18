pub const std = @import("std");
pub const pipelines = @import("../pipelines.zig");
pub const zlib = @import("../zlib/zlib.zig");
pub const chunks = @import("chunks.zig");
pub const utils = @import("utils.zig");
pub const Settings = @import("../shared/Settings.zig");

pub const levels = @import("../shared/level.zig");
usingnamespace levels;

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

// TODO: Only works assuming PNG is the top level of the tree.
pub fn isParserStateTerminal(context: *const Context) bool 
{
    return context.state.action == .Chunk
        and !context.level().infoMasks.isSetAtLevel(0);
}

pub const Context = struct
{
    common: @import("../shared/CommonContext.zig"),
    state: *State,

    pub fn level(self: *Context) levels.LevelContext(Context)
    {
        return .{
            .data = &self.common.level,
            .context = self,
        };
    }
    pub fn sequence(self: *Context) *pipelines.Sequence
    {
        return &self.common.sequence;
    }
    pub fn settings(self: *Context) *Settings
    {
        return &self.common.settings;
    }
    pub fn allocator(self: *Context) std.mem.Allocator
    {
        return self.common.allocator;
    }
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

