const helper = @import("helper.zig");

const SymbolDecompressionState = union(enum)
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

    const Initial: SymbolDecompressionState = .{ .Code7 = {} };
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

fn decompressSymbol(
    context: *helper.DeflateContext,
    state: *SymbolDecompressionState) !?helper.Symbol
{
    const lengthCodeUpperLimit = 0b001_0111;

    const literalLowerLimit = 0b0011_0000;
    const literalUpperLimit = 0b1011_1111;

    const lengthLowerLimit2 = 0b1100_0000;
    const lengthUpperLimit2 = 0b1101_1111;

    const literalLowerLimit2 = 0b1_1001_0000;

    switch (state.*)
    {
        .Code7 =>
        {
            const code = try helper.peekBits(context, u7);
            if (code.bits == 0)
            {
                code.apply(context);
                return .{ .endBlock = {} };
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
            const code = try helper.peekBits(context, u8);

            if (code.bits >= literalLowerLimit and code.bits <= literalUpperLimit)
            {
                code.apply(context);

                const value = code.bits - literalLowerLimit;
                state.* = SymbolDecompressionState.Initial;
                return .{ .literalValue = value };
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
                if (codeRemapped >= (286 - lengthCodeStart))
                {
                    return error.LengthCodeTooLarge;
                }

                return null;
            }

            state.* = .{ .Code9 = {} };
        },
        .Code9 =>
        {
            const code = try helper.readBits(context, u9);
            if (code >= literalLowerLimit2)
            {
                const literalOffset2 = literalUpperLimit - literalLowerLimit;
                const value = code - literalLowerLimit2 + literalOffset2;
                state.* = SymbolDecompressionState.Initial;
                return .{ .literalValue = value };
            }

            state.* = .{ .Code9Value = code };
            return error.DisallowedDeflateCodeValue;
        },
        .Length => |l|
        {
            const lengthBitCount = getLengthBitCount(l.codeRemapped);
            const extraBits = try helper.readBits(context, lengthBitCount);
            const baseLength = getBaseLength(l.codeRemapped);
            const length = baseLength + extraBits;
            state.* = .{ 
                .Distance = .{
                    .length = length,
                },
            };
        },
        .DistanceCode => |d|
        {
            const distanceCode = try helper.readBits(context, u5);
            state.* = .{
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
            const extraBits = try helper.readBits(context, distanceBitCount);
            const baseDistance = getBaseDistance(d.distanceCode);
            const distance = baseDistance + extraBits;

            state.* = SymbolDecompressionState.Initial;
            return .{
                .distance = distance + 1,
                .length = @as(u16, d.length) + 3,
            };
        },
    }

    return null;
}
