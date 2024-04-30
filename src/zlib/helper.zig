pub const pipelines = @import("../pipelines.zig");
pub const DeflateContext = @import("deflate.zig").Context;
pub const std = @import("std");
pub const huffman = @import("huffmanTree.zig");

pub const levels = @import("../shared/level.zig");
usingnamespace levels;

pub const Settings = @import("../shared/Settings.zig");
const SharedCommonContext = @import("../shared/CommonContext.zig");

pub const PeekApplyHelper = struct
{
    nextBitOffset: u3,
    nextSequenceStart: pipelines.SequencePosition,

    pub fn apply(self: PeekApplyHelper, context: *DeflateContext) void
    {
        context.state.bitOffset = self.nextBitOffset;
        context.sequence().* = context.sequence().sliceFrom(self.nextSequenceStart);
    }
};

pub fn PeekNBitsResult(resultType: type) type
{
    return struct
    {
        bits: resultType,
        applyHelper: PeekApplyHelper,

        const Self = @This();

        pub fn apply(self: Self, context: *DeflateContext) void
        {
            self.applyHelper.apply(context);
        }
    };
}

pub const PeekNBitsContext = struct
{
    context: *DeflateContext,
    bitsCount: u6,
    reverse: bool = false,

    fn sequence(self: *const PeekNBitsContext) *const pipelines.Sequence
    {
        return self.context.sequence();
    }

    fn bitOffset(self: *const PeekNBitsContext) u3
    {
        return self.context.state.bitOffset;
    }
};

pub fn peekNBits(context: PeekNBitsContext) !PeekNBitsResult(u32)
{
    if (context.bitsCount == 0)
    {
        return error.ReadingNoBits;
    }

    const ResultType = u32;
    const len = context.sequence().len();
    if (len == 0)
    {
        return error.NotEnoughBytes;
    }

    const availableBits = len * 8 - context.bitOffset();
    if (availableBits < context.bitsCount)
    {
        return error.NotEnoughBytes;
    }

    var bitOffset = context.bitOffset();
    var bitsRead: u6 = 0;
    var result: ResultType = 0;

    var iterator = pipelines.SegmentIterator.create(context.sequence()).?;
    const newPosition = newStart: while (true)
    {
        const slice = iterator.current();
        for (0 .., slice) |byteIndex, byte|
        {
            std.debug.assert(bitsRead < context.bitsCount);

            const availableByteBitCount: u4 = @intCast(@as(u8, 8) - @as(u8, bitOffset));
            const byteBits = byte >> bitOffset;
            std.debug.assert(availableByteBitCount > 0);

            const bitCountLeftToRead = context.bitsCount - bitsRead;
            std.debug.assert(bitCountLeftToRead > 0);

            const bitCountWillRead = @min(bitCountLeftToRead, availableByteBitCount);
            std.debug.assert(bitCountWillRead > 0);

            bitOffset = @intCast((@as(u8, bitOffset) + @as(u8, bitCountWillRead)) % 8);
            
            const willReadMask = @as(u8, 0xFF) >> @intCast(@as(u8, 8) - @as(u8, bitCountWillRead));
            const readBits_ = byteBits & willReadMask;
            const readBitsAsResultType: ResultType = @intCast(readBits_);

            if (context.reverse)
            {
                const c = context.bitsCount - bitsRead - 1;
                for (0 .. bitCountWillRead) |i|
                {

                    const bit = (readBitsAsResultType >> @intCast(i)) & 1;
                    result |= bit << @intCast(c - i);
                }
            }
            else
            {
                result |= readBitsAsResultType << @intCast(bitsRead);
            }

            bitsRead += bitCountWillRead;

            if (bitsRead == context.bitsCount)
            {
                const byteOffset = byteOffset:
                {
                    var r = byteIndex;
                    const readLastByteFully = bitOffset == 0;
                    if (readLastByteFully)
                    {
                        r += 1;
                    }
                    break :byteOffset r;
                };
                break :newStart iterator.currentPosition.add(@intCast(byteOffset));
            }
        }

        const advanced = iterator.advance();
        std.debug.assert(advanced);
    };

    return .{
        .bits = result,
        .applyHelper = .{
            .nextBitOffset = bitOffset,
            .nextSequenceStart = newPosition,
        },
    };
}

const BitsTestContext = struct
{
    allocator: std.mem.Allocator,
    buffer: pipelines.BufferManager,
    sequence: pipelines.Sequence = undefined,
    state: @import("deflate.zig").State = .{},
    common: CommonContext = undefined,
    settings: Settings,

    pub fn reset(self: *BitsTestContext) void
    {
        self.sequence = pipelines.Sequence.create(&self.buffer);
        self.state.bitOffset = 0;
    }

    pub fn init(self: *BitsTestContext) void
    {
        self.common = .{
            .sequence = &self.sequence,
            .allocator = self.allocator,
            .output = undefined,
        };
        self.sequence = pipelines.Sequence.create(&self.buffer);
    }

    pub fn context(self: *BitsTestContext) DeflateContext
    {
        return .{
            .common = &self.common,
            .state = &self.state,
        };
    }
};

fn createTestContext() !BitsTestContext
{
    const allocator = std.heap.page_allocator;
    const buffer = try pipelines.createTestBufferFromData(&.{"\x01\x23\x45", "\x67\x89"}, allocator); 
    const result = BitsTestContext
    {
        .allocator = allocator,
        .buffer = buffer,
    };
    return result;
}

const expectEqual = std.testing.expectEqual;

test "ApplyHelper works"
{
    var testContext = try createTestContext();
    testContext.init();

    const newStart = testContext.sequence().getPosition(4);
    const newOffset = 3;
    const helper = PeekApplyHelper
    {
        .nextBitOffset = newOffset,
        .nextSequenceStart = newStart,
    };
    helper.apply(&testContext.context());

    const start = testContext.sequence().start();
    try expectEqual(newStart.offset, start.offset);
    try expectEqual(newStart.segment, start.segment);
    try expectEqual(newOffset, testContext.state.bitOffset);

}

test "Peek bits test"
{
    var testContext = try createTestContext();
    testContext.init();

    const context = &testContext.context();

    {
        const r = try peekNBits(.{
            .bitsCount = 4,
            .context = context,
        });

        try expectEqual(1, r.bits);
        // Advance bit count by 4.
        // Now reading the 0.
        r.apply(context);

        try expectEqual(0, testContext.sequence().start().offset);
        try expectEqual(4, testContext.state.bitOffset);
    }

    // Check wrapping.
    {
        const r = try peekNBits(.{
            .bitsCount = 8,
            .context = context,
        });

        try expectEqual(0x30, r.bits);

        // Move on to the 2.
        r.apply(context);
    }

    // Num bits > 8
    {
        const r = try peekNBits(.{
            .bitsCount = 13,
            .context = context,
        });

        // 2, 4, 5, lower 1 bits of 7
        // 7 = 0111
        try expectEqual(0x1_45_2, r.bits);

        r.apply(context);
    }

    testContext.reset();

    // Test the limit: reading 32 bytes.
    {
        const r = try peekNBits(.{
            .bitsCount = 32,
            .context = context,
        });

        try expectEqual(0x67_45_23_01, r.bits);
        r.apply(context);
    }

    // Reading just a single bit
    // 9 = 1001 --> 100  1
    {
        const r = try peekNBits(.{
            .bitsCount = 1,
            .context = context,
        });
        try expectEqual(1, r.bits);
        r.apply(context);
    }

    // Reading one bit at an odd position
    // 100 --> 10  0
    {
        const r = try peekNBits(.{
            .bitsCount = 1,
            .context = context,
        });
        try expectEqual(0, r.bits);
    }

    // Reading one bit at last offset should roll back to 0.
    testContext.state.bitOffset = 7;
    {
        const r = try peekNBits(.{
            .bitsCount = 1,
            .context = context,
        });
        // 8 -> 1000, reading the MSB
        try expectEqual(1, r.bits);
        try expectEqual(0, r.applyHelper.nextBitOffset);
    }

    testContext.reset();

    // In reverse mode, *the bits* are written backwards.
    {
        const r = try peekNBits(.{
            .bitsCount = 16,
            .context = context,
            .reverse = true,
        });

        // 0001 0000 0011 0010   Right-To-Left (bits), Left-To-Right (per number)
        // 1    0    3    2
        // 1000 0000 1100 0100   Left-To-Right (bits), Left-To-Right (per number)
        // 8    0    C    4
        try expectEqual(0x80C4, r.bits);
    }
}

pub const PeekBitsContext = struct
{
    context: *DeflateContext,
    reverse: bool = false,
};

pub fn peekBits(context: PeekBitsContext, ResultType: type)
    !PeekNBitsResult(ResultType)
{
    const bitsCount = comptime b:
    {
        const typeInfo = @typeInfo(ResultType);
        const bitsCount: u4 = @intCast(typeInfo.Int.bits);
        break :b bitsCount;
    };

    std.debug.assert(bitsCount <= 32 and bitsCount > 0);

    const result = try peekNBits(.{
        .context = context.context,
        .bitsCount = bitsCount,
        .reverse = context.reverse,
    });

    return .{
        .bits = @intCast(result.bits),
        .applyHelper = result.applyHelper,
    };
}

pub fn readBits(context: PeekBitsContext, ResultType: type) !ResultType
{
    const r = try peekBits(context, ResultType);
    r.apply(context.context);
    return r.bits;
}

pub fn readNBits(context: *DeflateContext, bitsCount: u6) !u32
{
    std.debug.assert(bitsCount > 0);
    const r = try peekNBits(.{
        .context = context,
        .bitsCount = bitsCount,
    });
    r.apply(context);
    return @intCast(r.bits);
}

pub const DecodedCharacterResult = struct
{
    character: huffman.DecodedCharacter,
    applyHelper: PeekApplyHelper,
    currentBitCount: *u5,

    pub fn apply(self: *const DecodedCharacterResult, context: *DeflateContext) void
    {
        self.applyHelper.apply(context);
        self.currentBitCount.* = 0;
    }
};

pub fn readAndDecodeCharacter(context: *DeflateContext, huffman_: HuffmanContext) !u16
{
    const r = try peekAndDecodeCharacter(context, huffman_);
    r.apply(context);
    return r.character;
}

fn peekAndDecodeCharacter(context: *DeflateContext, huffman_: HuffmanContext) !DecodedCharacterResult
{
    if (huffman_.currentBitCount.* == 0)
    {
        huffman_.currentBitCount.* = huffman_.tree.getInitialBitCount();
    }

    while (true)
    {
        const code = try peekNBits(.{
            .context = context,
            .bitsCount = huffman_.currentBitCount.*,
            .reverse = true,
        });
        const decoded = try huffman_.tree.tryDecode(
            @intCast(code.bits),
            huffman_.currentBitCount.*);
        switch (decoded)
        {
            .DecodedCharacter => |ch|
            {
                return .{
                    .character = ch,
                    .applyHelper = code.applyHelper,
                    .currentBitCount = huffman_.currentBitCount,
                };
            },
            .NextBitCount => |bitCount|
            {
                huffman_.currentBitCount.* = bitCount;
            },
        }
    }
}

pub const HuffmanContext = struct
{
    tree: *huffman.Tree,
    // Could make this store the currently read number as well if needed for optimization.
    // Adding on just a single bit is easier than rereading the whole thing.
    // So this ideally should be wrapped in a HuffamState sort of struct.
    currentBitCount: *u5,
};

pub fn readArrayElement(
    context: *DeflateContext,
    array: anytype, 
    currentNumberOfElements: *usize,
    bitsCount: u5) !bool
{
    if (currentNumberOfElements.* < array.len)
    {
        const value = try readNBits(context, bitsCount);
        array[currentNumberOfElements.*] = @intCast(value);
        currentNumberOfElements.* += 1;
    }
    if (currentNumberOfElements.* == array.len)
    {
        currentNumberOfElements.* = 0;
        return true;
    }
    return false;
}

pub const CommonContext = struct
{
    common: SharedCommonContext,
    output: *OutputBuffer,

    pub fn sequence(self: *CommonContext) *pipelines.Sequence
    {
        return self.common.sequence;
    }
    pub fn allocator(self: *CommonContext) std.mem.Allocator
    {
        return self.common.allocator;
    }
    pub fn settings(self: *CommonContext) *Settings
    {
        return self.common.settings;
    }
    pub fn level(self: *CommonContext) *levels.LevelContextData
    {
        return &self.common.level;
    }
};

pub const OutputBuffer = struct
{
    array: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    windowSize: *const usize,

    pub fn position(self: *const OutputBuffer) usize
    {
        return self.buffer().len;
    }

    pub fn buffer(self: *const OutputBuffer) []u8
    {
        return self.array.items;
    }

    pub fn deinit(self: *OutputBuffer) void
    {
        self.array.deinit(self.allocator);
    }

    pub fn writeByte(self: *OutputBuffer, byte: u8) !void
    {
        try self.array.append(self.allocator, byte);
    }

    pub fn writeBytes(self: *OutputBuffer, b: []const u8) !void
    {
        try self.array.appendSlice(self.allocator, b);
    }

    pub fn copyFromSelf(self: *OutputBuffer, backRef: BackReference) !void
    {
        std.debug.print("Buffer len: {}, distance: {}, windowSize: {}\n", .{self.buffer().len, backRef.distance, self.windowSize.*});

        if (self.buffer().len < backRef.distance)
        {
            return error.BackReferenceDistanceTooLarge;
        }

        if (backRef.distance == 0)
        {
            return error.BackReferenceDistanceIsZero;
        }

        if (backRef.distance > self.windowSize.*)
        {
            return error.BackReferenceDistanceTooLarge;
        }

        // NOTE: the memory can overlap here.
        for (0 .. backRef.len) |_|
        {
            const byte = self.buffer()[self.position() - backRef.distance];
            try self.writeByte(byte);
        }
    }
};

pub const BackReference = struct
{
    distance: u16,
    len: u16,
};

pub const Symbol = union(enum)
{
    EndBlock: void,
    LiteralValue: u8,
    BackReference: BackReference,
};

pub fn writeSymbolToOutput(context: *DeflateContext, symbol: ?Symbol) !bool
{
    if (symbol) |s|
    {
        const done = try writeSymbolToOutput_switch(context, s);
        if (done)
        {
            return true;
        }
    }
    return false;
}

fn writeSymbolToOutput_switch(context: *DeflateContext, symbol: Symbol) !bool
{
    switch (symbol)
    {
        .EndBlock =>
        {
            return true;
        },
        .LiteralValue => |literal|
        {
            try context.output().writeByte(literal);
        },
        .BackReference => |backReference|
        {
            try context.output().copyFromSelf(backReference);
        },
    }
    return false;
}

