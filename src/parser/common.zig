pub const std = @import("std");
pub const pipelines = @import("../pipelines.zig");
pub const zlib = @import("../zlib/zlib.zig");
pub const chunks = @import("chunks.zig");
pub const utils = @import("utils.zig");


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
    action: Initiable(Action) = .{ 
        .key = .Signature,
    },

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
    return state.action.key == .Chunk 
        and !state.action.initialized;
}

pub const Context = struct
{
    state: *State,
    sequence: *pipelines.Sequence,
    allocator: std.mem.Allocator,
    settings: *const Settings,
};

pub const Settings = struct
{
    logChunkStart: bool,
    returnOnInit: bool = false,
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
    action: Initiable(ChunkAction) = .{ .key = .Length },
    object: Chunk,
    dataState: chunks.ChunkDataState,
};

fn MaybeConst(Self: type, Result: type) type
{
    const info = @typeInfo(Self);
    if (info.Pointer.is_const)
    {
        return *const Result;
    }
    else
    {
        return *Result;
    }
}

pub fn InitiableThroughPointer(ActionType: type) type
{
    return struct
    {
        key: *ActionType,
        initialized: *bool,

        const Self = @This();

        pub fn keyPointer(self: anytype) MaybeConst(@TypeOf(self), ActionType)
        {
            return self.key;
        }
        pub fn initializedPointer(self: anytype) MaybeConst(@TypeOf(self), bool)
        {
            return self.initialized;
        }
    };
}

pub fn Initiable(ActionType: type) type
{
    return struct
    {
        key: ActionType,
        initialized: bool = false,

        const Self = @This();

        pub fn keyPointer(self: anytype) MaybeConst(@TypeOf(self), ActionType)
        {
            return &self.key;
        }
        pub fn initializedPointer(self: anytype) MaybeConst(@TypeOf(self), bool)
        {
            return &self.initialized;
        }
    };
}

pub fn initStateForAction(
    context: *const Context,
    // see common.Initiable
    action: anytype,
    // fn(*const Context, @TypeOf(action.key)) anyerror!void
    initialize: anytype) !void
{
    if (@typeInfo(@TypeOf(action)) != .Pointer)
    {
        @compileLog("Action must be passed by reference");
    }

    if (action.initializedPointer().*)
    {
        return;
    }

    if (@hasDecl(@TypeOf(initialize), "execute"))
    {
        try initialize.execute();
    }

    else if (@TypeOf(initialize) != void)
    {
        try initialize(context, action.keyPointer().*);
    }

    action.initializedPointer().* = true;

    if (context.settings.returnOnInit)
    {
        return error.StateInitialized;
    }
}

