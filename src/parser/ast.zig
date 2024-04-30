const std = @import("std");
const pipelines = @import("pipelines.zig");
const parser = @import("parser.zig");
const zlib = @import("../zlib/zlib.zig");
const deflate = @import("../zlib/deflate.zig");
const chunks = parser.chunks;

pub const NodeId = usize;
pub const DataId = usize;

const invalidNodeId: NodeId = @bitCast(@as(isize, -1));
const invalidDataId: NodeId = @bitCast(@as(isize, -1));

pub const NodeType = union(enum)
{
    TopLevel: parser.Action,
    Chunk: parser.ChunkAction,
    RGBColor: void,
    RGBComponent: chunks.RGBAction,

    ImageHeader: chunks.ImageHeaderAction,
    PrimaryChrom: chunks.PrimaryChromState,
    ICCProfile: chunks.ICCProfileAction,
    TextAction: chunks.TextAction,
    CompressedText: chunks.CompressedTextAction,
    RenderingIntent: void,

    Zlib: zlib.Action,
    Deflate: deflate.Action,
    NoCompression: deflate.noCompression.InitStateAction,
    FixedHuffman: deflate.fixed.SymbolDecompressionAction,
    DynamicHuffman: union(enum)
    {
        Decompression: deflate.dynamic.DecompressionAction,
        CodeDecoding: deflate.dynamic.CodeDecodingAction,
        CodeFrequency: deflate.dynamic.CodeFrequencyAction,
    },

    // Data from some nodes is skipped.
    Skipped: void,

    pub fn format(
        self: NodeType,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype) !void
    {
        switch (self)
        {
            inline else => |v| try writer.print("{}", .{ v }),
        }
    }
};

pub const NodeValue = union(enum)
{
    String: []const u8,
    OwnedString: std.ArrayListUnmanaged(u8),
    Number: usize,
    U32: u32,
    ChunkType: parser.ChunkType,
    None: void,
    ColorType: chunks.ColorType,
    CompressionMethod: chunks.CompressionMethod,
    FilterMethod: chunks.FilterMethod,
    InterlaceMethod: chunks.InterlaceMethod,
    RenderingIntent: chunks.RenderingIntent,
};

// Semantic node
pub const NodeData = struct
{
    type: NodeType,
    value: NodeValue,
};

pub const NodePositionOffset = struct
{
    byte: isize = 0,
    bit: isize = 0,

    pub fn addBits(self: NodePositionOffset, bits: isize) NodePositionOffset
    {
        return .{
            .byte = self.byte,
            .bit = self.bit + bits,
        };
    }

    pub fn negate(self: NodePositionOffset) NodePositionOffset
    {
        return .{
            .byte = -self.byte,
            .bit = -self.bit,
        };
    }

    pub fn add(a: NodePositionOffset, b: NodePositionOffset) NodePositionOffset
    {
        return .{
            .byte = a.byte + b.byte,
            .bit = a.bit + b.bit,
        };
    }

    pub fn normalized(self: NodePositionOffset) NodePositionOffset
    {
        return .{
            .byte = self.byte + @divFloor(self.bit, @bitSizeOf(u8)),
            .bit = @mod(self.bit, @bitSizeOf(u8)),
        };
    }

    pub fn isLessThanOrEqualToZero(self: NodePositionOffset) bool
    {
        const n = self.normalized();
        return n.byte <= 0 and n.byte == 0;
    }
};


test "Normalization"
{
    const doNodeOffsetNormalizationTest = struct
    {
        fn f(
            before: NodePositionOffset,
            after: NodePositionOffset) !void
        {
            const norm = before.normalized();
            try std.testing.expectEqualDeep(after, norm);
        }
    }.f;

    try doNodeOffsetNormalizationTest(
        .{ .byte = 0, .bit = -17, },
        .{ .byte = -3, .bit = 7, });

    try doNodeOffsetNormalizationTest(
        .{ .byte = 0, .bit = 17, },
        .{ .byte = 2, .bit = 1, });
}

pub const Position = struct
{
    byte: usize,
    bit: u3,

    pub fn compareTo(a: Position, b: Position) isize
    {
        const byteDiff = @as(isize, @intCast(a.byte)) - @as(isize, @intCast(b.byte));
        if (byteDiff != 0)
        {
            return byteDiff;
        }

        const bitDiff = @as(isize, @intCast(a.bit)) - @as(isize, @intCast(b.bit));
        return bitDiff;
    }

    fn asOffset(self: Position) NodePositionOffset
    {
        return .{
            .byte = @intCast(self.byte),
            .bit = @intCast(self.bit),
        };
    }

    pub fn offsetTo(a: Position, b: Position) NodePositionOffset
    {
        const fromNegative = a.asOffset().negate();
        const to = b.asOffset();
        const result = fromNegative.add(to);
        return result;
    }

    fn fromOffset(offset: NodePositionOffset) Position
    {
        return .{
            .byte = @intCast(offset.byte),
            .bit = @intCast(offset.bit),
        };
    }

    pub fn add(self: Position, added: NodePositionOffset) Position
    {
        const resultOffset = self.asOffset().add(added).normalized();
        std.debug.assert(resultOffset.byte >= 0);
        const result = fromOffset(resultOffset);
        return result;
    }
};

pub const NodeSpan = struct
{
    start: Position,
    endInclusive: Position,

    pub fn bitLen(span: *const NodeSpan) usize
    {
        const difference = span.start.offsetTo(span.endInclusive);
        const bitsDiff = difference.byte * @bitSizeOf(u8) + difference.bit + 1;
        return bitsDiff;
    }

    pub fn fromStartAndEndExclusive(startPos: Position, endPosExclusive: Position) NodeSpan
    {
        const comparison = endPosExclusive.compareTo(startPos);
        std.debug.assert(comparison > 0);
        const endInclusive_ = endPosExclusive.add(.{ .bit = -1 });
        return .{
            .start = startPos,
            .endInclusive = endInclusive_,
        };
    }

    pub fn fromStartAndLen(startPos: Position, len: NodePositionOffset) NodeSpan
    {
        const endOffset = len.addBits(-1);
        std.debug.assert(!endOffset.isLessThanOrEqualToZero());

        return .{
            .start = startPos,
            .endInclusive = startPos.add(endOffset),
        };
    }
};


pub const NodeSemanticContext = struct
{
    semanticNodeIds: std.ArrayListUnmanaged(DataId) = .{},
};
