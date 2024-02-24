const std = @import("std");
const pipelines = @import("pipelines.zig");

const ZlibHeader = struct
{
    compressionMethod: CompressionMethodAndFlags,
    flags: Flags,
    dictionaryId: u4,
};

const ZlibState = struct
{
    // Adler-32 checksum
    checksum: u32,
};

const CompressionMethodAndFlags = packed struct
{
    compressionMethod: CompressionMethod,
    compressionInfo: CompressionInfo,
};

const CompressionMethod = enum(u4)
{
    Deflate = 8,
    Reserved = 15,
};

const CompressionInfo = u4;

const Flags = packed struct
{
    check: u4,
    presetDictionary: bool,
    compressionLevel: CompressionLevel,
};

const CompressionLevel = enum(u3)
{
    Fastest = 0,
    Fast = 1,
    Default = 2,
    SlowMaximumCompression = 3,
};

const PresetDictionary = struct {};

fn checkCheckFlag(cmf: CompressionMethodAndFlags, flags: Flags) bool
{
    const cmfByte: u8 = @bitCast(cmf);
    const flagsByte: u8 = @bitCast(flags);
    const value: u16 = (cmfByte << 8) | flagsByte;
    const remainder = value % 31;
    return remainder == 0;
}

const BlockType = enum(u2)
{
    NoCompression = 0,
    FixedHuffman = 1,
    DynamicHuffman = 2,
    Reserved = 3,
};

const DeflateContext = struct
{
    sequence: *pipelines.Sequence,
    state: *DeflateState,
    allocator: std.mem.Allocator,
};

const DeflateState = struct
{
    action: DeflateStateAction,
    bitOffset: u4,

    isFinal: bool,
    blockType: BlockType,
    len: u16,

    dataBytesRead: u16,
    symbol: SymbolState,
};

const SymbolState = union(enum)
{
    Code7: void,
    Code8: struct
    {
        code7: u7,
    },
    Code9: struct
    {
        code8: u8,
    },
    Code9Value: u9,
    Length: struct
    {
        codeRemapped: u8,
    },
    DistanceCode: struct
    {
        length: u8,
    },
    Distance: struct
    {
        length: u8,
        distanceCode: u5,
    },
    Done: Symbol,

    const Initial: SymbolState = .{ .Code7 = {} };
};

const DeflateStateAction = enum
{
    IsFinal,
    BlockType,

    NoCompressionLen,
    NoCompressionNLen,
    UncompressedBytes,

    DecompressionLoop,
};

pub fn readNBits(context: *DeflateContext, resultType: type) !resultType
{
    const bitsCount = comptime b:
    {
        const typeInfo = @typeInfo(resultType);
        const bitsCount: u4 = @intCast(typeInfo.Int.bits);
        std.debug.assert(bitsCount <= 8);
        break :b bitsCount;
    };

    const len = context.sequence.len();
    if (len == 0)
    {
        return error.NotEnoughBytes;
    }

    const availableBits = len * 8 - context.state.bitOffset;
    if (availableBits < bitsCount)
    {
        return error.NotEnoughBytes;
    }

    const bitOffset = &context.state.bitOffset;
    const firstByteBitsLeft = 8 - bitOffset.*;

    const s = context.sequence;
    const firstByte = s.peekFirstByte().?;
    const mask = 0xFF >> (8 - bitsCount);
    const firstByteBits = (firstByte >> bitOffset.*) & mask;

    if (firstByteBitsLeft > bitsCount)
    {
        bitOffset.* += bitsCount;
        return firstByteBits;
    }

    s.* = s.sliceFrom(s.getPosition(1));

    const bitsLeftToRead = bitsCount - firstByteBitsLeft;
    bitOffset.* = bitsLeftToRead;

    if (bitsLeftToRead == 0)
    {
        return firstByteBits;
    }

    const secondByte = s.peekFirstByte().?;
    const secondByteBits = secondByte >> (8 - bitsLeftToRead);
    const result = firstByteBits | (secondByteBits << firstByteBitsLeft);
    return result;
}

const BackReference = struct
{
    unadjustedDistance: u16,
    unadjustedLength: u8,

    pub fn length(self: BackReference) u8
    {
        return self.unadjustedLength + 3;
    }
    pub fn distance(self: BackReference) u16
    {
        return self.unadjustedDistance + 1;
    }
};

const Symbol = union(enum)
{
    endBlock: void,
    literalValue: u8,
    backReference: BackReference,
};

const lengthCodeStart = 257;

fn getLengthBitCount(code: u8) u8
{
    const s = lengthCodeStart;
    return switch (code)
    {
        (257 - s) ... (264 - s), (285 - s) => 0,
        else => (code - (265 - s)) / 4 + 1,
    };
}

const baseLengthLookup = l:
{
    const count = 285 - lengthCodeStart;
    var result: [count + 1]u8 = undefined;
    for (0 .. 8) |i|
    {
        result[i] = i;
    }

    for (8 .. count) |i|
    {
        const bitCount = getLengthBitCount(i);
        const representableNumberCount = 1 << bitCount;
        result[i] = result[i - 1] + representableNumberCount;
    }

    result[count] = 0;

    break :l result;
};

fn getBaseLength(code: u8) u8
{
    return baseLengthLookup[code];
}

fn getDistanceBitCount(distanceCode: u5) u8
{
    return switch (distanceCode)
    {
        0 ... 1 => 0,
        else => distanceCode / 2 - 1,
    };
}

const baseDistanceLookup = l:
{
    const count = 30;
    var result: [count]u16 = undefined;
    for (0 .. 2) |i|
    {
        result[i] = i;
    }
    for (2 .. count) |i|
    {
        const bitCount = getDistanceBitCount(i);
        const representableNumberCount = 1 << bitCount;
        result[i] = result[i - 1] + representableNumberCount;
    }
    break :l result;
};

fn getBaseDistance(distanceCode: u5) u16
{
    return baseDistanceLookup[distanceCode];
}

fn readSymbol(context: *DeflateContext) !bool
{
    const symbol = &context.state.symbol;

    const lengthCodeUpperLimit = 0b001_0111;

    const literalLowerLimit = 0b0011_0000;
    const literalUpperLimit = 0b1011_1111;

    const lengthLowerLimit2 = 0b1100_0000;
    const lengthUpperLimit2 = 0b1101_1111;

    const literalLowerLimit2 = 0b1_1001_0000;

    switch (symbol.*)
    {
        .Code7 =>
        {
            const code7 = try readNBits(context, 7);
            if (code7 == 0)
            {
                return .{ .endBlock = {} };
            }

            if (code7 <= lengthCodeUpperLimit)
            {
                symbol.* = .{
                    .Length = .{ 
                        .codeRemapped = code7 - 1,
                    },
                };
                return false;
            }

            symbol.* = .{
                .Code8 = .{ 
                    .code7 = code7,
                },
            };
        },
        .Code8 => |c|
        {
            const bit8 = try readNBits(context, 1);
            const code8: u8 = (@as(u8, bit8) << 7) | @as(u8, c.code7);

            if (code8 >= literalLowerLimit and code8 <= literalUpperLimit)
            {
                const value = code8 - literalLowerLimit;
                symbol.* = .{ .literalValue = value };
                return true;
            }

            if (code8 >= lengthLowerLimit2 and code8 <= lengthUpperLimit2)
            {
                const codeRemapped = code8 - lengthLowerLimit2 + lengthCodeUpperLimit;
                symbol.* = .{ 
                    .Length = .{ 
                        .codeRemapped = codeRemapped,
                    }
                };
                if (codeRemapped >= (286 - lengthCodeStart))
                {
                    return error.LengthCodeTooLarge;
                }

                return false;
            }

            symbol.* = .{
                .Code9 = .{ 
                    .code8 = code8,
                },
            };
        },
        .Code9 => |c|
        {
            const bit9 = try readNBits(context, 1);
            const code9: u9 = (@as(u9, bit9) << 8) | @as(u9, c.code8);
            if (code9 >= literalLowerLimit2)
            {
                const literalOffset2 = literalUpperLimit - literalLowerLimit;
                const value = code9 - literalLowerLimit2 + literalOffset2;
                symbol.* = .{ .literalValue = value };
                return true;
            }

            symbol.* = .{ .Code9Value = code9 };
            return error.DisallowedDeflateCodeValue;
        },
        .Length => |l|
        {
            const lengthBitCount = getLengthBitCount(l.codeRemapped);
            const extraBits = try readNBits(context, lengthBitCount);
            const baseLength = getBaseLength(l.codeRemapped);
            const length = baseLength + extraBits;
            symbol.* = .{ 
                .Distance = .{
                    .length = length,
                },
            };
        },
        .DistanceCode => |d|
        {
            const distanceCode = try readNBits(context, 5);
            symbol.* = .{
                .Distance = .{
                    .length = d.length,
                    .distanceCode = distanceCode,
                },
            };

            if (distanceCode >= 30)
            {
                return error.InvalidDistanceCode;
            }
        },
        .Distance => |d|
        {
            const distanceBitCount = getDistanceBitCount(d.distanceCode);
            const extraBits = try readNBits(context, distanceBitCount);
            const baseDistance = getBaseDistance(d.distanceCode);
            const distance = baseDistance + extraBits;
            symbol.* = .{
                .Done = .{
                    .unadjustedDistance = distance,
                    .unadjustedLength = d.length,
                },
            };
            return true;
        },
        .Done => unreachable,
    }

    return false;
}

pub fn deflate(context: *DeflateContext) !void
{
    const state = context.state;
    switch (state.action)
    {
        .IsFinal =>
        {
            const isFinal = try readNBits(context, 1);
            state.isFinal = isFinal;
            state.action = DeflateStateAction.BlockType;
        },
        .BlockType =>
        {
            const blockType = try readNBits(context, 2);
            state.blockType = @enumFromInt(blockType);

            switch (state.blockType)
            {
                .NoCompression =>
                {
                    if (state.bitOffset != 0)
                    {
                        _ = pipelines.removeFirst(context.sequence) catch unreachable;
                        state.bitOffset = 0;
                    }
                    state.action = DeflateStateAction.NoCompressionLen;
                },
                .FixedHuffman =>
                {
                    // state.action = DeflateStateAction.FixedHuffman;
                },
                .Reserved =>
                {
                    return error.ReservedBlockTypeUsed;
                },
            }
        },
        .NoCompressionLen =>
        {
            const len = try pipelines.readNetworkUnsigned(context.sequence, u16);
            state.action = DeflateStateAction.NoCompressionNLen;
            state.len = len;
        },
        .NoCompressionNLen =>
        {
            const nlen = try pipelines.readNetworkUnsigned(context.sequence, u16);
            if (nlen != ~state.len)
            {
                return error.NLenNotOnesComplement;
            }
            state.action = .UncompressedBytes;
            state.dataBytesRead = 0;
        },
        .UncompressedBytes =>
        {
            // TODO:
            // use the read bytes helper, move it from the parser
            // into pipelines or pipelines.extensions
        },
    }
}

fn copyConst(from: type, to: type) type
{
    return @Type(t: {
        var info = @typeInfo(to).Pointer;
        info.is_const = @typeInfo(from).Pointer.is_const;
        break :t info;
    });
}

const HuffmanTree = struct
{
    prefixes: [MAX_PREFIX_COUNT]u16,
    decodedCharactersLookup: [MAX_PREFIX_COUNT][]u8,
    maxBitCount: u5,

    pub fn count(self: *HuffmanTree) usize
    {
        var c: usize = 0;
        for (self.decodedCharactersLookup) |arr|
        {
            c += arr.len;
        }
        return c;
    }

    pub fn deinit(self: *HuffmanTree, allocator: std.mem.Allocator) void
    {
        for (self.decodedCharactersLookup) |arr|
        {
            allocator.free(arr);
        }
    }

    pub const Iterator = struct
    {
        tree: *const HuffmanTree,
        bitIndex: u5,
        characterIndex: u8,

        pub fn next(self: *Iterator)
            ?struct {
                code: u16,
                bitCount: u5,
                decodedCharacter: u8,
            }
        {
            if (self.bitIndex > self.tree.maxBitCount)
            {
                return null;
            }

            const lookup = self.tree.decodedCharactersLookup[self.bitIndex];

            const prefix = self.tree.prefixes[self.bitIndex];
            const decodedCharacter = lookup[self.characterIndex];
            const bitCount = self.bitIndex + 1;
            const code = prefix + self.characterIndex;

            self.characterIndex += 1;
            if (self.characterIndex == lookup.len)
            {
                if (self.tree.getNextBitCount(self.bitIndex + 1)) |ni|
                {
                    self.bitIndex = ni - 1;
                }
                else
                {
                    self.bitIndex = self.tree.maxBitCount + 1;
                }
                self.characterIndex = 0;
            }

            return .{
                .code = code,
                .bitCount = bitCount,
                .decodedCharacter = decodedCharacter,
            };
        }
    };

    pub fn iterator(self: *const HuffmanTree) Iterator
    {
        const bitIndex = self.getNextBitCount(0) orelse self.maxBitCount + 1;
        return .{
            .tree = self,
            .bitIndex = bitIndex,
            .characterIndex = 0,
        };
    }

    const Lengths = struct
    {
        prefixLen: u4,
        bitCount: u5,
    };

    fn getNextBitCount(self: *const HuffmanTree, bitCount: u5) ?u5
    {
        const maxBitCount_ = self.maxBitCount;
        if (bitCount == maxBitCount_)
        {
            return null;
        }

        for ((bitCount + 1) .. (maxBitCount_ + 1)) |nextBitCount|
        {
            if (self.decodedCharactersLookup[nextBitCount - 1].len != 0)
            {
                return @intCast(nextBitCount);
            }
        }
        return null;
    }

    pub fn tryDecode(self: *const HuffmanTree, code: u16, bitCount: u5)
        !union(enum)
        {
            decodedCharacter: u8,
            nextBitCount: u5,
        }
    {
        const bitIndex: u4 = @intCast(bitCount - 1);

        const prefix = self.prefixes[bitIndex];

        const index = code -% prefix;
        const lookup = self.decodedCharactersLookup[bitIndex];

        if (code >= prefix and index < lookup.len)
        {
            return .{ 
                .decodedCharacter = lookup[index],
            };
        }
        else
        {
            const nextBitCount = self.getNextBitCount(bitCount)
                orelse return error.InvalidCode;

            return .{
                .nextBitCount = nextBitCount
            };
        }
    }
};

fn maxValue(array: anytype) @TypeOf(array[0])
{
    var result = array[0];
    for (array[1 ..]) |value|
    {
        if (value > result)
        {
            result = value;
        }
    }
    return result;
}

const MAX_CODE_LENGTH = @bitSizeOf(u16);
const MAX_PREFIX_COUNT = MAX_CODE_LENGTH - 1;

const HuffmanTreeCreationContext = struct
{
    _codeStartingValuesByLen: [MAX_PREFIX_COUNT]u16,
    _numberOfCodesByCodeLen: [MAX_PREFIX_COUNT]u16,
    bitLensBySymbol: []const u5,
    len: u5,

    fn maybeConst(self: type, num: type) type
    {
        return switch (self)
        {
            *HuffmanTreeCreationContext => []num,
            *const HuffmanTreeCreationContext => []const num,
            else => unreachable,
        };
    }

    pub fn codeStartingValuesByLen(self: anytype) maybeConst(@TypeOf(self), u16)
    {
        return self._codeStartingValuesByLen[0 .. self.len];
    }
    pub fn numberOfCodesByCodeLen(self: anytype) maybeConst(@TypeOf(self), u16)
    {
        return self._numberOfCodesByCodeLen[0 .. self.len];
    }
};

fn generateHuffmanTreeCreationContext(bitLensBySymbol: []const u5)
    !HuffmanTreeCreationContext
{
    const maxBits = maxValue(bitLensBySymbol);
    if (maxBits > MAX_CODE_LENGTH)
    {
        return error.MaxBitsTooLarge;
    }

    var r = std.mem.zeroInit(HuffmanTreeCreationContext, .{
        .len = maxBits,
        .bitLensBySymbol = bitLensBySymbol,
    });
    for (bitLensBySymbol) |bitLength|
    {
        r.numberOfCodesByCodeLen()[bitLength - 1] += 1;
    }

    var code: u16 = 0;
    for (0 .. maxBits) |bitIndex|
    {
        const count = r.numberOfCodesByCodeLen()[bitIndex];
        r.codeStartingValuesByLen()[bitIndex] = code;

        // I think this needs an overflow check?
        const allowedMask = ~@as(u16, 0) >> @intCast(16 - bitIndex - 1);
        if ((code & allowedMask) != code)
        {
            return error.InvalidHuffmanTree;
        }

        code = (code + count) << 1;
    }
    return r;
}

fn createHuffmanTree(
    t: *const HuffmanTreeCreationContext,
    allocator: std.mem.Allocator) !HuffmanTree
{
    var codes = std.mem.zeroInit(HuffmanTree, .{
        .maxBitCount = t.len,
        .prefixes = t._codeStartingValuesByLen,
    });

    for (codes.decodedCharactersLookup[0 .. t.len], t.numberOfCodesByCodeLen()) 
        |*lookup, count|
    {
        if (count != 0)
        {
            lookup.* = try allocator.alloc(u8, count);
        }
    }

    var counters: [MAX_PREFIX_COUNT]u8 = [_]u8{0} ** MAX_PREFIX_COUNT;

    for (0 .., t.bitLensBySymbol) |i, bitLen|
    {
        if (bitLen != 0)
        {
            const counter = &counters[bitLen - 1];
            codes.decodedCharactersLookup[bitLen - 1][counter.*] = @intCast(i);
            counter.* += 1;
        }
    }

    return codes;
}

test "huffman tree correct"
{
    const bitLens = &[_]u5{ 3, 3, 3, 3, 3, 2, 4, 4 };
    var codeStarts = try generateHuffmanTreeCreationContext(bitLens);

    const t = std.testing;
    try t.expectEqual(codeStarts.len, 4);
    try t.expectEqualSlices(u16, &[_]u16{ 0, 0, 2, 14 }, codeStarts.codeStartingValuesByLen());

    const allocator = std.heap.page_allocator;
    var tree = try createHuffmanTree(&codeStarts, allocator);
    defer tree.deinit(allocator);

    try t.expectEqual(8, tree.count());

    const alphabet = "ABCDEFGH";
    const expected = [_]u4
    {
        0b010,
        0b011,
        0b100,
        0b101,
        0b110,
        0b00,
        0b1110,
        0b1111,
    };

    if (false)
    {
        std.debug.print("tree:\n", .{});
        var iter = tree.iterator();
        while (iter.next()) |entry|
        {
            const code: u4 = @intCast(entry.code);
            const letter = entry.decodedCharacter + 'A';
            std.debug.print("letter: {[letter]c}; code: {[code]b:0>[bitCount]}\n", .{
                .letter = letter,
                .code = code,
                .bitCount = entry.bitCount,
            });
        }
    }

    for (alphabet, expected) |letter, expectedCode|
    {
        const letterIndex = letter - 'A';
        const bitLen = bitLens[letterIndex];
        const decoded = try tree.tryDecode(expectedCode, bitLen);
        try t.expectEqual(letterIndex, decoded.decodedCharacter);
    }
}
