const helper = @import("helper.zig");
const std = helper.std;

pub const SymbolDecompressionAction = enum
{
    Code,
    Len,
    DistanceCode,
    Distance,
};

// 7 || 8 || 9
pub const CodeState = u4;

pub const SymbolDecompressionState = struct
{
    action: SymbolDecompressionAction = .Code,
    codeLen: CodeState = 7,
    lenCode: u8,
    len: u8,
    distanceLenCode: u5,
    distance: u16,

    pub const Initial = std.mem.zeroInit(SymbolDecompressionState, .{
        .codeLen = 7,
        .action = .Code,
    });
};

const lengthCodeStart = 257;

fn adjustStart(offset: u16) u8
{
    return @intCast(offset - lengthCodeStart);
}

fn getLengthBitCount(code: u8) u6
{
    return switch (code)
    {
        adjustStart(257) ... adjustStart(264), adjustStart(285) => 0,
        else => @intCast((code - adjustStart(265)) / 4 + 1),
    };
}


fn testLengthBitCount(expected: u6, code: u16) !void
{
    const expect = std.testing.expectEqual;
    try expect(expected, getLengthBitCount(adjustStart(code)));
}

test
{
    try testLengthBitCount(0, 257);
    try testLengthBitCount(1, 267);
    try testLengthBitCount(4, 280);
    try testLengthBitCount(5, 281);
    try testLengthBitCount(5, 282);
}

const baseLengthLookup = l:
{
    const count = 285 - lengthCodeStart;
    var result: [count + 1]u8 = undefined;
    for (0 .. 8) |i|
    {
        result[i] = i;
    }

    var a = 8;
    for (8 .. count) |i|
    {
        result[i] = a;
        const bitCount = getLengthBitCount(i);
        const representableNumberCount = 1 << bitCount;
        a += representableNumberCount;
    }

    result[count] = 255;

    // for (0 .., result) |i, v|
    // {
    //     @compileLog(lengthCodeStart + i, @as(u32, v) + 3);
    // }

    break :l result;
};

fn getBaseLength(code: u9) u8
{
    return baseLengthLookup[code];
}

fn testBaseLength(expected: u16, code: u16) !void
{
    const expect = std.testing.expectEqual;
    try expect(expected, @as(u16, getBaseLength(adjustStart(code))) + 3);
}

test "Base length"
{
    try testBaseLength(3, 257);
    try testBaseLength(11, 265);
    try testBaseLength(19, 269);
    try testBaseLength(23, 270);
    try testBaseLength(227, 284);
    try testBaseLength(258, 285);
}

fn getDistanceBitCount(distanceCode: u5) u6
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
    var a = 2;
    for (2 .. count) |i|
    {
        result[i] = a;
        const bitCount = getDistanceBitCount(i);
        const representableNumberCount = 1 << bitCount;
        a += representableNumberCount;
    }
    break :l result;
};

fn getBaseDistance(distanceCode: u5) u16
{
    return baseDistanceLookup[distanceCode];
}

fn testBaseDistance(expected: u16, code: u5) !void
{
    const expect = std.testing.expectEqual;
    try expect(expected, getBaseDistance(code) + 1);
}

test "Base distance"
{
    try testBaseDistance(1, 0);
    try testBaseDistance(5, 4);
    try testBaseDistance(33, 10);
    try testBaseDistance(1025, 20);
    try testBaseDistance(24577, 29);
}

const DeflateContext = helper.DeflateContext;

pub fn decompressSymbol(
    context: *DeflateContext,
    state: *SymbolDecompressionState) !?helper.Symbol
{
    const result = try decompressSymbolImpl(context, state);
    if (result) |_|
    {
        state.* = SymbolDecompressionState.Initial;
    }
    return result;
}

pub fn decompressSymbolImpl(
    context: *DeflateContext,
    state: *SymbolDecompressionState) !?helper.Symbol
{
    try context.level().push();
    defer context.level().pop();

    const lengthCodeUpperLimit = 0b001_0111;

    const literalLowerLimit = 0b0011_0000;
    const literalUpperLimit = 0b1011_1111;

    const lengthLowerLimit2 = 0b1100_0000;
    const lengthUpperLimit2 = 0b1101_1111;

    const literalLowerLimit2 = 0b1_1001_0000;

    const readCodeBitsContext = helper.PeekBitsContext
    {
        .context = context,
        .reverse = true,
    };

    const nodeCreator = DecompressionNodeWriter
    {
        .context = context,
    };

    switch (state.action)
    {
        .Code =>
        {
            while (true)
            {
                const code = try helper.peekNBits(.{
                    .context = context,
                    .bitsCount = state.codeLen,
                    .reverse = true,
                });

                switch (state.codeLen)
                {
                    7 =>
                    {
                        if (code.bits == 0)
                        {
                            code.apply(context);
                            try nodeCreator.create(.EndBlock, 0);

                            return .{ .EndBlock = {} };
                        }

                        if (code.bits <= lengthCodeUpperLimit)
                        {
                            code.apply(context);
                            state.lenCode = @intCast(code.bits - 1);
                            state.action = .Len;

                            try nodeCreator.create(.LenCodeLen, state.lenCode);

                            return null;
                        }
                    },
                    8 =>
                    {
                        if (code.bits >= literalLowerLimit and code.bits <= literalUpperLimit)
                        {
                            code.apply(context);

                            const value = code.bits - literalLowerLimit;

                            try nodeCreator.create(.Literal, value);

                            return .{ .LiteralValue = @intCast(value) };
                        }

                        if (code.bits >= lengthLowerLimit2 and code.bits <= lengthUpperLimit2)
                        {
                            code.apply(context);

                            const codeRemapped = code.bits - lengthLowerLimit2 + lengthCodeUpperLimit;
                            state.lenCode = @intCast(codeRemapped);
                            state.action = .Len;

                            try nodeCreator.create(.LenCodeLen, codeRemapped);

                            if (codeRemapped >= adjustStart(286))
                            {
                                return error.LengthCodeTooLarge;
                            }
                            return null;
                        }
                    },
                    9 =>
                    {
                        code.apply(context);

                        if (code.bits >= literalLowerLimit2)
                        {
                            const literalOffset2 = 144;
                            const value = code.bits - literalLowerLimit2 + literalOffset2;
                            try nodeCreator.create(.Literal, value);
                            return .{ .LiteralValue = @intCast(value) };
                        }

                        return error.DisallowedDeflateCodeValue;
                    },
                    else => unreachable,
                }
                state.codeLen += 1;
            }
        },
        .Len =>
        {
            const lengthBitCount = getLengthBitCount(state.lenCode);
            const extraBits = if (lengthBitCount == 0)
                    0
                else
                    try helper.readNBits(context, lengthBitCount);

            const baseLength = getBaseLength(state.lenCode);
            const len = baseLength + extraBits;
            state.len = @intCast(len);

            try nodeCreator.create(.Len, len);

            state.action = .DistanceCode;
        },
        .DistanceCode =>
        {
            const distanceCode = try helper.readBits(readCodeBitsContext, u5);
            state.action = .Distance;
            state.distanceLenCode = distanceCode;

            try nodeCreator.create(.DistanceLenCode, distanceCode);

            if (distanceCode >= 30)
            {
                return error.InvalidDistanceCode;
            }
        },
        .Distance =>
        {
            const distanceBitCount = getDistanceBitCount(state.distanceLenCode);
            const extraBits = if (distanceBitCount == 0)
                    0
                else
                    try helper.readNBits(context, distanceBitCount);

            const baseDistance = getBaseDistance(state.distanceLenCode);
            const distance = baseDistance + @as(u16, @intCast(extraBits));
            state.distance = distance;

            try nodeCreator.create(.Distance, distance);

            state.action = .Code;

            return .{
                .BackReference = .{
                    .distance = @intCast(distance + 1),
                    .len = @as(u16, state.len) + 3,
                },
            };
        },
    }

    return null;
}

pub const DecompressionValueType = enum
{
    Literal,
    Len,
    EndBlock,
    Distance,

    // TODO: allow semantic nodes to store more useful data.
    LenCodeLen,
    DistanceLenCode,
};

const DecompressionNodeWriter = struct
{
    context: *DeflateContext,

    pub fn create(self: @This(), t: DecompressionValueType, value: usize) !void
    {
        self.context.level().setNodeType(.{
            .FixedHuffmanDecompression = t,
        });
        try self.context.level().completeNodeWithValue(.{
            .Number = value,
        });
    }
};
