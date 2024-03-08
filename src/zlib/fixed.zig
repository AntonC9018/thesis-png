const helper = @import("helper.zig");
const std = helper.std;

pub const SymbolDecompressionState = union(enum)
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
        len: u8,
    },
    Distance: struct
    {
        len: u8,
        distanceCode: u5,
    },

    pub const Initial: SymbolDecompressionState = .{ .Code7 = {} };
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

fn getBaseLength(code: u8) u8
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

pub fn decompressSymbol(
    context: *const helper.DeflateContext,
    state: *SymbolDecompressionState) !?helper.Symbol
{
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

    switch (state.*)
    {
        .Code7 =>
        {
            const code = try helper.peekBits(readCodeBitsContext, u7);
            if (code.bits == 0)
            {
                code.apply(context);
                return .{ .EndBlock = {} };
            }

            if (code.bits <= lengthCodeUpperLimit)
            {
                code.apply(context);
                state.* = .{
                    .Length = .{ 
                        .codeRemapped = code.bits - 1,
                    },
                };
                return null;
            }

            state.* = .{ .Code8 = {} };
        },
        .Code8 =>
        {
            const code = try helper.peekBits(readCodeBitsContext, u8);

            if (code.bits >= literalLowerLimit and code.bits <= literalUpperLimit)
            {
                code.apply(context);

                const value = code.bits - literalLowerLimit;
                state.* = SymbolDecompressionState.Initial;
                return .{ .LiteralValue = value };
            }

            if (code.bits >= lengthLowerLimit2 and code.bits <= lengthUpperLimit2)
            {
                code.apply(context);

                const codeRemapped = code.bits - lengthLowerLimit2 + lengthCodeUpperLimit;
                state.* = .{ 
                    .Length = .{ 
                        .codeRemapped = codeRemapped,
                    }
                };
                if (codeRemapped >= adjustStart(286))
                {
                    return error.LengthCodeTooLarge;
                }

                return null;
            }

            state.* = .{ .Code9 = {} };
        },
        .Code9 =>
        {
            const code = try helper.readBits(readCodeBitsContext, u9);
            if (code >= literalLowerLimit2)
            {
                const literalOffset2 = 144;
                const value = code - literalLowerLimit2 + literalOffset2;
                state.* = SymbolDecompressionState.Initial;
                return .{ .LiteralValue = @intCast(value) };
            }

            state.* = .{ .Code9Value = code };
            return error.DisallowedDeflateCodeValue;
        },
        .Length => |l|
        {
            const lengthBitCount = getLengthBitCount(l.codeRemapped);
            const extraBits = if (lengthBitCount == 0)
                    0
                else
                    try helper.readNBits(context, lengthBitCount);

            const baseLength = getBaseLength(l.codeRemapped);
            const len = baseLength + extraBits;
            state.* = .{ 
                .DistanceCode = .{
                    .len = @intCast(len),
                },
            };
        },
        .DistanceCode => |d|
        {
            const distanceCode = try helper.readBits(readCodeBitsContext, u5);
            state.* = .{
                .Distance = .{
                    .len = d.len,
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
            const extraBits = if (distanceBitCount == 0)
                    0
                else
                    try helper.readNBits(context, distanceBitCount);

            const baseDistance = getBaseDistance(d.distanceCode);
            std.debug.print("Distance code: {}\n", .{d.distanceCode});
            std.debug.print("Extra bits: {}\n", .{extraBits});
            std.debug.print("Base distance: {}\n", .{baseDistance});
            const distance = baseDistance + extraBits;

            state.* = SymbolDecompressionState.Initial;
            return .{
                .BackReference = .{
                    .distance = @intCast(distance + 1),
                    .len = @as(u16, d.len) + 3,
                },
            };
        },
        .Code9Value => unreachable,
    }

    return null;
}
