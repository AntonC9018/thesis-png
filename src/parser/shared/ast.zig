const std = @import("std");
const parser = @import("../module.zig");
const pipelines = parser.pipelines;
const zlib = parser.zlib;
const deflate = zlib.deflate;
const chunks = parser.png.chunks;

pub const NodeId = usize;
pub const NodeDataId = usize;

pub const invalidNodeId: NodeId = @bitCast(@as(isize, -1));
pub const invalidNodeDataId: NodeDataId = invalidNodeId;

pub const NodeType = union(enum)
{
    TopLevel: parser.png.Action,
    Chunk: parser.png.ChunkAction,
    RGBColor: void,
    RGBComponent: chunks.RGBAction,

    ImageHeader: chunks.ImageHeaderAction,
    PrimaryChrom: chunks.PrimaryChromAction,
    ICCProfile: chunks.ICCProfileAction,
    TextAction: chunks.TextAction,
    CompressedText: chunks.CompressedTextAction,
    RenderingIntent: void,
    PhysicalPixelDimensions: chunks.PhysicalPixedDimensionsAction,

    ZlibContainer: void,

    Zlib: zlib.Action,
    Deflate: deflate.Action,
    DeflateCode: void,
    NoCompression: deflate.noCompression.InitStateAction,
    FixedHuffmanDecompression: deflate.fixed.DecompressionValueType,
    ZlibSymbol: void,
    DynamicHuffman: union(enum)
    {
        DecompressionValue: deflate.dynamic.DecompressionValueType,
        CodeDecoding: deflate.dynamic.CodeDecodingAction,
        CodeFrequency: deflate.dynamic.CodeFrequencyAction,
        EncodedFrequency: void,
    },

    Container: void,

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

pub const NodeData = union(enum)
{
    LiteralString: []const u8,
    // The memory is from the context's allocator.
    OwnedString: std.ArrayListUnmanaged(u8),
    Number: u64,
    U32: u32,
    Bool: bool,
    ChunkType: parser.png.ChunkType,
    RGB: chunks.RGB,
    RGB16: chunks.RGB16,

    ColorType: chunks.ColorType,
    CompressionMethod: chunks.CompressionMethod,
    FilterMethod: chunks.FilterMethod,
    InterlaceMethod: chunks.InterlaceMethod,
    RenderingIntent: chunks.RenderingIntent,
    PixelUnitSpecifier: chunks.PixelUnitSpecifier,

    CompressionMethodAndFlags: zlib.CompressionMethodAndFlags,
    ZlibFlags: zlib.Flags,
    BlockType: deflate.BlockType,
    ZlibSymbol: deflate.Symbol,

//     pub fn format(
//         self: @This(),
//         comptime _: []const u8,
//         _: std.fmt.FormatOptions,
//         writer: anytype) !void
//     {
//         _ = self;
//         try writer.print("placeholder?", .{});
//     }
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
