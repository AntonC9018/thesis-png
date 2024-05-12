const std = @import("std");

pub const DecodedCharacter = u16;

pub const Tree = struct
{
    prefixes: [MAX_PREFIX_COUNT]u16,
    decodedCharactersLookup: [MAX_PREFIX_COUNT][]DecodedCharacter,
    maxBitCount: u5,

    pub fn count(self: *Tree) usize
    {
        var c: usize = 0;
        for (self.decodedCharactersLookup) |arr|
        {
            c += arr.len;
        }
        return c;
    }

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void
    {
        for (&self.decodedCharactersLookup) |*arr|
        {
            allocator.free(arr.*);
            arr.* = &.{};
        }
    }
    
    fn getNextBitIndexOrMax(self: *Tree, startBitIndex: u5) u5
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
        tree: *const Tree,
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
                self.bitIndex = self.tree.getNextBitIndexOrMax(self.bitIndex + 1);
                self.characterIndex = 0;
            }

            return .{
                .code = code,
                .bitCount = bitCount,
                .decodedCharacter = decodedCharacter,
            };
        }
    };

    pub fn iterator(self: *const Tree) Iterator
    {
        const bitIndex = self.getNextBitIndexOrMax(0);
        return .{
            .tree = self,
            .bitIndex = bitIndex,
            .characterIndex = 0,
        };
    }

    fn getNextBitCount(self: *const Tree, bitCount: u5) ?u5
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

    pub fn getInitialBitCount(self: *const Tree) u5
    {
        return self.getNextBitCount(0).?;
    }

    // Segment HuffmanDecode begin
    pub fn tryDecode(self: *const Tree, code: u16, bitCount: u5)
        !union(enum)
        {
            DecodedCharacter: DecodedCharacter,
            NextBitCount: u5,
        }
    {
        const bitIndex: u4 = @intCast(bitCount - 1);

        const prefix = self.prefixes[bitIndex];
        const lookup = self.decodedCharactersLookup[bitIndex];

        if (code >= prefix and code < prefix + lookup.len)
        {
            const index = code - prefix;
            return .{ 
                .DecodedCharacter = lookup[index],
            };
        }
        else
        {
            const nextBitCount = self.getNextBitCount(bitCount)
                orelse
                {
                    return error.InvalidCode;
                };

            return .{
                .NextBitCount = nextBitCount
            };
        }
    }
    // Segment HuffmanDecode end
};

pub fn createTree(
    bitLensBySymbol: []const u5,
    allocator: std.mem.Allocator) !Tree
{
    const t = try generateTreeCreationContext(bitLensBySymbol);
    const tree = try createTreeFromContext(&t, allocator);
    return tree;
}

const MAX_CODE_LENGTH = @bitSizeOf(u16);
const MAX_PREFIX_COUNT = MAX_CODE_LENGTH - 1;

const TreeCreationContext = struct
{
    _codeStartingValuesByLen: [MAX_PREFIX_COUNT]u16,
    _numberOfCodesByCodeLen: [MAX_PREFIX_COUNT]u16,
    bitLensBySymbol: []const u5,
    len: u5,

    fn maybeConst(self: type, num: type) type
    {
        return switch (self)
        {
            *TreeCreationContext => []num,
            *const TreeCreationContext => []const num,
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

fn generateTreeCreationContext(bitLensBySymbol: []const u5)
    !TreeCreationContext
{
    const maxBits = maxValue(bitLensBySymbol);
    if (maxBits > MAX_CODE_LENGTH)
    {
        return error.MaxBitsTooLarge;
    }

    var r = std.mem.zeroInit(TreeCreationContext, .{
        .len = maxBits,
        .bitLensBySymbol = bitLensBySymbol,
    });
    for (bitLensBySymbol) |bitLength|
    {
        if (bitLength != 0)
        {
            r.numberOfCodesByCodeLen()[bitLength - 1] += 1;
        }
    }

    var code: u16 = 0;
    for (0 .. maxBits) |bitIndex|
    {
        const count = r.numberOfCodesByCodeLen()[bitIndex];
        r.codeStartingValuesByLen()[bitIndex] = code;

        if (false) {
            // I think this needs an overflow check?
            // TODO: Something is wrong with this check, I can't quite put my finger on it.
            const allowedMask = (~@as(u16, 0)) >> @intCast(16 - bitIndex - 1);
            if ((code & allowedMask) != code)
            {
                return error.InvalidHuffmanTree;
            }
        }

        code = (code + count) << 1;
    }
    return r;
}

// Segment CreateTree begin
fn createTreeFromContext(
    t: *const TreeCreationContext,
    allocator: std.mem.Allocator) !Tree
{
    var codes = std.mem.zeroInit(Tree, .{
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
// Segment CreateTree end

test "huffman tree correct"
{
    const bitLens = &[_]u5{ 3, 3, 3, 3, 3, 2, 4, 4 };
    var codeStarts = try generateTreeCreationContext(bitLens);

    const t = std.testing;
    try t.expectEqual(codeStarts.len, 4);
    try t.expectEqualSlices(u16, &[_]u16{ 0, 0, 2, 14 }, codeStarts.codeStartingValuesByLen());

    const allocator = std.heap.page_allocator;
    var tree = try createTreeFromContext(&codeStarts, allocator);
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

