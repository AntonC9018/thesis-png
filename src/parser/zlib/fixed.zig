const helper = @import("helper.zig");
const std = helper.std;
const symbolLimits = helper.symbolLimits;
const DistanceCode = symbolLimits.DistanceCode;
const LenCode = symbolLimits.LenCode;

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
    lenCodeLen: CodeState = 7,
    lenCode: symbolLimits.LenCode,
    len: symbolLimits.Len,
    distanceCode: symbolLimits.DistanceCode,

    pub const Initial = std.mem.zeroInit(SymbolDecompressionState, .{
        .lenCodeLen = 7,
        .action = .Code,
    });
};

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

    const nodeCreator = helper.DecompressionNodeWriter
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
                    .bitsCount = state.lenCodeLen,
                    .reverse = true,
                });

                switch (state.lenCodeLen)
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
                            state.lenCode = @enumFromInt(code.bits - 1);
                            state.action = .Len;

                            try nodeCreator.create(.LenCodeExtra, @intFromEnum(state.lenCode));

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
                            state.lenCode = @enumFromInt(codeRemapped);
                            state.action = .Len;

                            try nodeCreator.create(.LenCodeExtra, codeRemapped);

                            if (codeRemapped > LenCode.lastCode)
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
                state.lenCodeLen += 1;
            }
        },
        .Len =>
        {
            const lengthBitCount = state.lenCode.extraBitCount();
            const extraBits = if (lengthBitCount == 0)
                    0
                else
                    try helper.readNBits(context, lengthBitCount);

            const baseLength = state.lenCode.base();
            const len = @as(symbolLimits.Len, @intCast(baseLength)) + extraBits;
            state.len = @intCast(len);

            try nodeCreator.create(.Len, len);

            state.action = .DistanceCode;
        },
        .DistanceCode =>
        {
            const distanceCode = try helper.readBits(readCodeBitsContext, u5);
            state.action = .Distance;
            state.distanceCode = @enumFromInt(distanceCode);

            try nodeCreator.create(.Distance, distanceCode);

            if (distanceCode >= 30)
            {
                return error.InvalidDistanceCode;
            }
        },
        .Distance =>
        {
            const distanceBitCount = state.distanceCode.extraBitCount();
            const extraBits = if (distanceBitCount == 0)
                    0
                else
                    try helper.readNBits(context, distanceBitCount);

            const baseDistance = state.distanceCode.base();
            const distance = baseDistance + @as(symbolLimits.Distance, @intCast(extraBits));

            try nodeCreator.create(.DistanceExtra, extraBits);

            state.action = .Code;

            return .{
                .BackReference = .{
                    .distance = distance,
                    .len = state.len,
                },
            };
        },
    }

    return null;
}
