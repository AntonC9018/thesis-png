const std = @import("std");
const pipelines = @import("pipelines.zig");
const parser = @import("parser/parser.zig");
const zlib = @import("zlib/zlib.zig");
const deflate = @import("zlib/deflate.zig");
const chunks = parser.chunks;

const resourcesDir = "raylib/raylib/examples/text/resources/";

// 1. Transform parser results into tree
// 2. Draw bytes on screen
// 3. Draw image
// 4. Visualize the tree
// 5. Allow switching pages changing the current range
// 6. Deleting invisible parts of the tree
//

const ChildrenList = struct
{
    array: std.ArrayListUnmanaged(usize) = .{},

    pub fn len(self: *const ChildrenList) usize
    {
        return self.array.items.len;
    }
};

pub const ChunkDataNodeType = parser.ChunkType;

const NodeIndex = usize;
const DataIndex = usize;

const NodeType = union(enum)
{
    TopLevel: parser.Action,
    Chunk: parser.ChunkAction,

    ChunkData: union(enum)
    {
        RGB: chunks.RGBAction,
        ImageHeader: chunks.ImageHeaderAction,
        PrimaryChrom: chunks.PrimaryChromState,
        ICCProfile: chunks.ICCProfileAction,
        TextAction: chunks.TextAction,
        CompressedText: chunks.CompressedTextAction,
    },

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

const Data = struct
{
    // Maybe add a reference count here to be able to know when to delete things.
    type: NodeType,
    value: union(enum)
    {
        String: []const u8,
        Number: usize,
        ChunkType: parser.ChunkType,
        None: void,
    },
};

const bitsInByte = 8;

const NodePositionOffset = struct
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
            .byte = self.byte + @divFloor(self.bit, bitsInByte),
            .bit = @mod(self.bit, bitsInByte),
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

const Position = struct
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

const NodeSpan = struct
{
    start: Position,
    endInclusive: Position,

    pub fn bitLen(span: *const NodeSpan) usize
    {
        const difference = span.start.offsetTo(span.endInclusive);
        const bitsDiff = difference.byte * bitsInByte + difference.bit + 1;
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

const Node = struct
{
    // In case there are child nodes, includes the position of the start
    // of the first child node, and the end position of the last child node.
    // The idea is that there may be gaps in the range of the span,
    // but it does allow you to gauge the edges.
    // If there are no children, it's just the range of the node.
    span: NodeSpan,
    nodeData: ?DataIndex,
    children: ChildrenList,
};

const AST = struct
{
    rootNodes: std.ArrayList(NodeIndex),
    nodes: std.ArrayList(Node),
    nodeData: std.ArrayList(Data),

    pub fn childrenAllocator(self: *AST) std.mem.Allocator
    {
        return self.nodes.allocator;
    }
};

pub fn createTestTree(allocator: std.mem.Allocator) !AST
{
    var tree: AST = .{
        .rootNodes = std.ArrayList(usize).init(allocator),
        .nodes = std.ArrayList(Node).init(allocator),
        .nodeData = std.ArrayList(Data).init(allocator),
    };
    const data = try tree.nodeData.addManyAsArray(10);
    const defaultType = NodeType { .TopLevel = .Chunk };
    data.*[0] = .{
        .type = defaultType,
        .value = .{
            .string = "Test",
        },
    };
    data.*[1] = .{
        .type = defaultType,
        .value = .{
            .string = "Hello world, this is a longer piece of text",
        },
    };
    for (2 .. data.len) |i|
    {
        data.*[i] = .{
            .type = defaultType,
            .value = .{
                .number = i,
            },
        };
    }

    var position = Position
    {
        .byte = 0,
        .bit = 0,
    };

    {
        const endPosition = position.add(.{ .byte = 1 });
        const node = Node
        {
            .span = NodeSpan.fromStartAndEndExclusive(position, endPosition),
            .nodeData = null,
            .children = .{},
        };
        try tree.nodes.append(node);
        position = endPosition;
    }
    // Make a couple nodes to serve as children.
    const childrenCount = 3;
    const parentNode = try tree.nodes.addOne();

    var children: ChildrenList = .{};
    try children.array.ensureTotalCapacity(tree.childrenAllocator(), childrenCount);

    for (0 .. childrenCount) |i|
    {
        const endPosition = position.add(.{
            .byte = @intCast(i + 1),
            .bit = @intCast(i * 6),
        });
        // std.debug.print("From: {d},{d}\n", .{ position.byte, position.bit });
        // std.debug.print("To: {d},{d}\n", .{ endPosition.byte, endPosition.bit });
        const node = Node
        {
            .span = NodeSpan.fromStartAndEndExclusive(position, endPosition),
            .nodeData = i,
            .children = .{},
        };
        const currentIndex = tree.nodes.items.len;
        try children.array.append(tree.childrenAllocator(), currentIndex);
        try tree.nodes.append(node);
        position = endPosition;
    }

    {
        const childIndices = children.array.items;
        const firstChild = childIndices[0];
        const lastChild = childIndices[childIndices.len - 1];

        const start = tree.nodes.items[firstChild].span.start;
        const end = tree.nodes.items[lastChild].span.endInclusive;
        parentNode.* = Node
        {
            .span = .{
                .start = start,
                .endInclusive = end,
            },
            .nodeData = null,
            .children = children,
        };
    }

    (try tree.rootNodes.addManyAsArray(2)).* = .{ 0, 1 };
    return tree;
}
