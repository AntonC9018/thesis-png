pub const std = @import("std");
pub const chunks = @import("chunks.zig");
pub const utils = @import("utils.zig");

const parser = @import("../module.zig");
usingnamespace parser;

pub const ast = parser.ast;
pub const zlib = parser.zlib;
pub const pipelines = parser.pipelines;
pub const Settings = parser.Settings;

const levels = parser.level;
usingnamespace levels;

// What is the next expected type?
pub const TopLevelAction = enum
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
    action: TopLevelAction = .Signature,

    imageHeader: ?chunks.ImageHeader = null,
    // True after the IEND chunk has been parsed.
    isEnd: bool = false,
    // True after the first IDAT chunk data start being parsed.
    isData: bool = false,
    paletteLen: ?u32 = null,

    imageData: ImageDataState = .{},
};

pub fn isParserStateTerminal(context: *Context) bool 
{
    return context.state.isEnd
        and context.nodeContext().syntaxNodeStack.items.len == 0;
}

pub const Context = struct
{
    common: @import("../shared/CommonContext.zig"),
    state: *State,

    // Indicates that the sequence slice currently contained in sequence()
    // is the last one for this chunk, meaning the functions that e.g. skip all bytes
    // in the chunk, or read all bytes in the chunk should look at this bool
    // to determine if they're completely done after having processed all of the sequence.
    isLastChunkSequenceSlice: bool = undefined,

    pub fn level(self: *Context) levels.LevelContext(Context)
    {
        return .{
            .data = &self.common.level,
            .context = self,
        };
    }
    pub fn sequence(self: *Context) *pipelines.Sequence
    {
        return self.common.sequence;
    }
    pub fn settings(self: *Context) *const Settings
    {
        return self.common.settings;
    }
    pub fn allocator(self: *Context) std.mem.Allocator
    {
        return self.common.allocator;
    }
    pub fn getStartBytePosition(self: *Context) parser.ast.Position
    {
        return .{
            .byte = self.sequence().getStartBytePosition(),
            .bit = 0,
        };
    }
    pub fn nodeContext(self: *Context) *parser.NodeContext
    {
        return self.common.nodeContext;
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
pub const ImageDataState = struct
{
    // Just read the raw bytes for now
    bytes: std.ArrayListUnmanaged(u8) = .{},
    zlib: zlib.State = .{},
    carryOverData: CarryOverSegment = .{},
    dataId: ast.NodeDataId = ast.invalidNodeDataId,
    zlibStreamSemanticContext: levels.NodeSemanticContext = .{},
};

pub const CyclicRedundancyCheck = struct
{
    value: u32,
};

pub const Chunk = struct
{
    dataByteLen: u32,
    type: chunks.ChunkType,
    isKnownType: bool,
    crc: CyclicRedundancyCheck,
};

// Segment CRC begin
const crcTable = crcTable:
{
    var result: [256]u32 = undefined;
    @setEvalBranchQuota(256 * 8 * 2);

    for (0 .., &result) |i, *r|
    {
        var c: u32 = i;
        for (0 .. 8) |_|
        {
            if (c % 2 == 1)
            {
                c = 0xedb88320 ^ (c >> 1);
            }
            else
            {
                c >>= 1;
            }
        }

        r.* = c;
    }

    break :crcTable result;
};

pub fn updateCrc(state: u32, sequence: pipelines.Sequence) u32
{
    var iter = sequence.iterate() orelse return state;
    var c = state;
    while (true)
    {
        for (iter.current()) |byte|
        {
            const index = (c ^ byte) & 0xFF;
            c = crcTable[index] ^ c >> 8;
        }

        if (!iter.advance())
        {
            return c;
        }
    }
}
// Segment CRC end

pub const ChunkState = struct
{
    action: ChunkAction = .Length,
    object: Chunk,
    dataState: chunks.ChunkDataState,
    crcState: u32 = @bitCast(@as(i32, -1)),
    bytesRead: u32 = 0,
};

pub fn move(t: anytype) @TypeOf(t.*)
{
    const result = t.*;
    t.* = .{};
    return result;
}

pub fn ExhaustiveVariant(t: type) type
{
    var info = @typeInfo(t);
    info.Enum.is_exhaustive = true;
    info.Enum.decls = &.{};
    return @Type(info);
}

pub fn exhaustive(t: anytype) ExhaustiveVariant(@TypeOf(t))
{
    return @enumFromInt(@intFromEnum(t));
}

pub fn nameOfEnumMember(e: anytype) ?[]const u8
{
    const info = @typeInfo(@TypeOf(e)); 
    inline for (info.Enum.fields) |f|
    {
        if (f.value == @intFromEnum(e))
        {
            return f.name;
        }
    }
    return null;
}
