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
    len: u16,

    dataBytesRead: u16,
    symbol: SymbolState,

    blockState: union(BlockType)
    {
        NoCompression: void,
        FixedHuffman: void,
        DynamicHuffman: DynamicHuffmanState,
        Reserved: void,
    },
};

const SymbolState = union(enum)
{
    Code7: void,
    Code8: void,
    Code9: void,
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

const DynamicHuffmanAction = enum
{
    LiteralOrLenCodeCount,
    DistanceCodeCount,
    CodeLenCount,
    CodeLens,
    LiteralOrLenCodeLens,
    DistanceCodeLens,
};

const HuffmanParsingState = struct
{
    tree: HuffmanTree,
    currentBitCount: u5,
};

const CodeFrequencyAction = enum
{
    LiteralLen,
    RepeatCount,
    Done,
};

const CodeFrequencyState = struct
{
    action: CodeFrequencyAction,
    huffman: HuffmanParsingState,
    decodedLen: u5,
    repeatCount: u7,

    pub fn repeatBitCount(self: *const CodeFrequencyState) u5
    {
        return switch (self.decodedLen)
        {
            16 => 2,
            17 => 3,
            18 => 7,
            else => unreachable,
        };
    }
};

const DynamicHuffmanState = struct
{
    action: DynamicHuffmanAction,
    literalOrLenCodeCount: u5,
    distanceCodeCount: u5,
    codeLenCodeCount: u4,

    // Reset as it's being read.
    readListItemCount: usize,
    codeFrequencyState: CodeFrequencyState,

    codeLens: [19]u3,
    literalOrLengthCodeLens: []u8,
    distances: []u8,

    pub fn getLenCodeCount(self: *const DynamicHuffmanState) usize
    {
        return self.literalOrLenCodeCount + 4;
    }
};

fn PeekNBitsResult(resultType: type) type
{
    return struct
    {
        bits: resultType,
        nextBitOffset: u4,
        nextSequenceStart: pipelines.SequencePosition,

        const Self = @This();

        pub fn apply(self: Self, context1: *DeflateContext) void
        {
            context1.state.bitOffset = self.nextBitOffset;
            context1.sequence.* = context1.sequence.sliceFrom(self.nextSequenceStart);
        }
    };
}

pub fn peekNBits(context: *DeflateContext, bitsCount: u6) u32
    !PeekNBitsResult(u32)
{
    const ResultType = u16;
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

    var bitOffset = context.state.bitOffset;
    var bitsRead = 0;
    var result: ResultType = 0;

    var iterator = pipelines.SegmentIterator.create(context.sequence).?;
    while (bitsRead < bitsCount)
    {
        const byte = iterator.current();
        const availableByteBitCount = 8 - bitOffset;
        const byteBits = byte >> bitOffset;

        const bitCountLeftToRead = bitsCount - bitsRead;
        const bitCountWillRead = @min(bitCountLeftToRead, availableByteBitCount);
        bitOffset = (bitOffset + bitCountWillRead) % 8;

        const willReadMask = 0xFF >> (8 - bitCountWillRead);
        const readBits = byteBits & willReadMask;
        const readBitsAsResultType: ResultType = @intCast(readBits);
        result |= readBitsAsResultType << bitsRead;
        bitsRead += bitCountWillRead;

        if (bitCountWillRead >= availableByteBitCount)
        {
            const advanced = iterator.advance();
            std.debug.assert(advanced);
        }
    }

    return .{
        .bits = result,
        .nextBitOffset = bitOffset,
        .nextSequenceStart = iterator.sequence.start(),
    };
}

pub fn peekBits(context: *DeflateContext, ResultType: type)
    !PeekNBitsResult(ResultType)
{
    const bitsCount = comptime b:
    {
        const typeInfo = @typeInfo(ResultType);
        const bitsCount: u4 = @intCast(typeInfo.Int.bits);
        break :b bitsCount;
    };

    std.debug.assert(bitsCount <= 32 and bitsCount > 0);

    return @intCast(peekNBits(context, bitsCount));
}

pub fn readBits(context: *DeflateContext, ResultType: type) !ResultType
{
    const r = try peekBits(context, ResultType);
    r.apply(context);
    return r.bits;
}

pub fn readNBits(context: *DeflateContext, bitCount: u6) !u32
{
    const r = try peekNBits(context, bitCount);
    r.apply(context);
    return @intCast(r.bits);
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
            const code = try peekBits(context, u7);
            if (code.bits == 0)
            {
                code.apply(context);
                return .{ .endBlock = {} };
            }

            if (code.bits <= lengthCodeUpperLimit)
            {
                code.apply(context);
                symbol.* = .{
                    .Length = .{ 
                        .codeRemapped = code.bits - 1,
                    },
                };
                return false;
            }

            symbol.* = .{ .Code8 = {} };
        },
        .Code8 =>
        {
            const code = try peekBits(context, u8);

            if (code.bits >= literalLowerLimit and code.bits <= literalUpperLimit)
            {
                code.apply(context);

                const value = code.bits - literalLowerLimit;
                symbol.* = .{ .literalValue = value };
                return true;
            }

            if (code.bits >= lengthLowerLimit2 and code.bits <= lengthUpperLimit2)
            {
                code.apply(context);

                const codeRemapped = code.bits - lengthLowerLimit2 + lengthCodeUpperLimit;
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

            symbol.* = .{ .Code9 = {} };
        },
        .Code9 =>
        {
            const code = try readBits(context, u9);
            if (code >= literalLowerLimit2)
            {
                const literalOffset2 = literalUpperLimit - literalLowerLimit;
                const value = code - literalLowerLimit2 + literalOffset2;
                symbol.* = .{ .literalValue = value };
                return true;
            }

            symbol.* = .{ .Code9Value = code };
            return error.DisallowedDeflateCodeValue;
        },
        .Length => |l|
        {
            const lengthBitCount = getLengthBitCount(l.codeRemapped);
            const extraBits = try readBits(context, lengthBitCount);
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
            const distanceCode = try readBits(context, u5);
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
            const extraBits = try readBits(context, distanceBitCount);
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
            const isFinal = try readBits(context, u1);
            state.isFinal = isFinal;
            state.action = DeflateStateAction.BlockType;
        },
        .BlockType =>
        {
            const blockType = try readBits(context, u2);
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
                .DynamicHuffman =>
                {
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

const DecodedCharacter = u16;

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
    
    fn getNextBitIndex(self: *HuffmanTree, startBitIndex: u5) u5
    {
        if (self.getNextBitCount(startBitIndex)) |ni|
        {
            return ni - 1;
        }
        else
        {
            return self.maxBitCount;
        }
    }

    pub const Iterator = struct
    {
        tree: *const HuffmanTree,
        bitIndex: u5,
        characterIndex: u8,

        pub fn next(self: *Iterator)
            ?struct
            {
                code: u16,
                bitCount: u5,
                decodedCharacter: DecodedCharacter,
            }
        {
            if (self.bitIndex == self.tree.maxBitCount)
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
                self.bitIndex = self.tree.getNextBitIndex(self.bitIndex + 1);
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
        const bitIndex = self.getNextBitIndex(0);
        return .{
            .tree = self,
            .bitIndex = bitIndex,
            .characterIndex = 0,
        };
    }

    fn getNextBitCount(self: *const HuffmanTree, bitCount: u5) ?u5
    {
        for ((bitCount + 1) .. (self.maxBitCount + 1)) |nextBitCount|
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
            DecodedCharacter: DecodedCharacter,
            NextBitCount: u5,
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
            lookup.* = try allocator.alloc(DecodedCharacter, count);
        }
    }

    var counters: [MAX_PREFIX_COUNT]DecodedCharacter = [_]DecodedCharacter{0} ** MAX_PREFIX_COUNT;

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

fn generateHuffmanTree(
    bitLensBySymbol: []const u5,
    allocator: std.mem.Allocator) !HuffmanTree
{
    const t = try generateHuffmanTreeCreationContext(bitLensBySymbol);
    const tree = try createHuffmanTree(&t, allocator);
    return tree;
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
        try t.expectEqual(letterIndex, decoded.DecodedCharacter);
    }
}

fn readArrayElement(
    context: *DeflateContext,
    array: anytype, 
    currentNumberOfElements: *usize,
    BitsType: type) !bool
{

    if (currentNumberOfElements.* < array.len)
    {
        const value = try readBits(context, BitsType);
        array[currentNumberOfElements.*] = value;
        currentNumberOfElements.* += 1;
    }
    if (currentNumberOfElements.* == array.len)
    {
        currentNumberOfElements.* = 0;
        return true;
    }
    return false;
}


pub fn parseDynamicHuffmanTree(
    context: *DeflateContext) !bool
{
    const state = &context.state.blockState.DynamicHuffman;

    switch (state.action)
    {
        // TODO:
        // Maybe actually really try using async here?
        // Code like this kills me.
        .LiteralOrLenCodeCount =>
        {
            const count = try readBits(context, u5);
            state.literalOrLenCodeCount = count;
            state.action = .DistanceCodeCount;
            return false;
        },
        .DistanceCodeCount =>
        {
            const count = try readBits(context, u5);
            state.distanceCodeCount = count;
            state.action = .CodeLenCount;
            return false;
        },
        .CodeLenCount =>
        {
            const count = try readBits(context, u4);
            state.codeLenCodeCount = count;
            state.action = .CodeLens;

            const codeLenCount = count + 4;
            state.codeLens = try context.allocator.alloc(u3, codeLenCount);

            return false;
        },
        .CodeLens =>
        {
            const readAllArray = readArrayElement(
                context,
                state.codeLens[0 .. state.getLenCodeCount()],
                &state.readListItemCount,
                u3);
            
            if (readAllArray)
            {
                state.action = .LiteralOrLenCodeLens;
                state.literalOrLengthCodeLens = try context.allocator
                    .alloc(u5, 257 + state.literalOrLenCodeCount);

                const copy = state.codeLens;
                for (0 .. state.getLenCodeCount()) |i|
                {
                    const orderArray = &[_]u5{
                        16, 17, 18, 0, 8,
                        7, 9, 6, 10, 5,
                        11, 4, 12, 3, 13,
                        2, 14, 1, 15,
                    };
                    const remappedIndex = orderArray[i];
                    state.codeLens[remappedIndex] = copy[i];

                    const tree = try generateHuffmanTree(
                        @ptrCast(state.codeLens),
                        context.allocator);
                    state.codeFrequencyState = .{
                        .action = .ReadCodeLen,
                        .codeLenTree = tree,
                        .currentBitCount = 0,
                        .len = 0,
                    };
                }
            }
            return false;
        },
        .LiteralOrLenCodeLens =>
        {
            const array = state.literalOrLengthCodeLens;
            const readCount = &state.readListItemCount;
            const freqState = &state.codeFrequencyState;
            if (readCount.* < array.len)
            {
                while (true)
                {
                    const done = try readLiteralOrLenCode(context, state);
                    if (done)
                    {
                        freqState.action = .LiteralLen;
                        break;
                    }
                }
            }

            if (readCount.* == array.len)
            {
                state.action = .DistanceCodeLens;
                state.distanceCodeLens = try context.allocator
                    .alloc(u5, 1 + state.distanceCodeCount);
                state.readListItemCount = 0;
            }

            return false;
        },
        .DistanceCodeLens =>
        {
            if (state.readListItemCount < state.distanceCodeLens.len)
            {
                const len = try readBits(context, 3);
                state.distances[state.readListItemCount] = len;
                state.readListItemCount += 1;
            }
            if (state.readListItemCount == state.distanceCodeLens.len)
            {
                state.action = .Done;
            }
            return false;
        },
    }
}

fn readAndDecodeCharacter(context: *DeflateContext, huffman: *HuffmanParsingState) !u16
{
    if (huffman.currentBitCount == 0)
    {
        huffman.currentBitCount = huffman.tree.getNextBitCount(0);
    }

    while (true)
    {
        const code = try peekNBits(context, huffman.currentBitCount);
        const decoded = try huffman.tree.tryDecode(@intCast(code.bits), huffman.currentBitCount);
        switch (decoded)
        {
            .DecodedCharacter => |ch|
            {
                code.apply(context);
                return ch;
            },
            .NextBitCount => |bitCount|
            {
                huffman.currentBitCount = bitCount;
            },
        }
    }
}

fn readLiteralOrLenCode(
    context: *DeflateContext,
    state: *DynamicHuffmanState) !bool
{
    const freqState = &state.codeFrequencyState;
    const outputArray = state.literalOrLengthCodeLens;
    const readCount = &state.readListItemCount;

    switch (freqState.action)
    {
        .LiteralLen =>
        {
            const character = try readAndDecodeCharacter(context, &freqState.huffman);
            const len: u5 = @intCast(character);

            std.debug.assert(len <= 18);

            if (len >= 16)
            {
                freqState.action = .RepeatCount;

                if (state.readCount.* == 0)
                {
                    return .NothingToRepeat;
                }

                return false;
            }

            freqState.action = .Done;
            outputArray[readCount.*] = len;
            readCount.* += 1;
            return true;
        },
        .RepeatCount =>
        {
            const repeatBitCount = freqState.repeatBitCount();
            const repeatCount = try readNBits(context, repeatBitCount);
            freqState.repeatCount = @intCast(repeatCount);

            const maxCanReadCount = outputArray.len - readCount.*;
            if (repeatCount > maxCanReadCount)
            {
                return error.InvalidRepeatCount;
            }

            const repeatedLen = outputArray[readCount.* - 1];

            for (0 .. repeatCount) |i|
            {
                const index = readCount.* + i;
                outputArray[index] = repeatedLen;
            }
            readCount.* += repeatCount;
            freqState.action = .Done;
            return true;
        },
        .Done => unreachable,
    }
}
