const std = @import("std");

pub const Distance = u16;

pub const DistanceCode = enum(u5)
{
    _,

    pub const firstCode = 0;
    pub const lastCode = 29;

    pub fn base(self: DistanceCode) Distance
    {
        return baseDistanceLookup[@intFromEnum(self)] + 1;
    }
    pub fn extraBitCount(self: DistanceCode) u6
    {
        return getDistanceBitCount(@intFromEnum(self));
    }
};

pub const Len = u9;

pub const LenCode = enum(u8)
{
    _,

    pub const firstCode = lengthCodeStart;
    pub const lastCode = 285;

    pub fn fromUnadjustedCode(code: u9) LenCode
    {
        return @enumFromInt(adjustStart(code));
    }
    pub fn base(self: LenCode) Len
    {
        return @as(Len, baseLengthLookup[@intFromEnum(self)]) + 3;
    }
    pub fn extraBitCount(self: LenCode) u6
    {
        return getLengthBitCount(@intFromEnum(self));
    }
};

const lengthCodeStart = 257;

fn adjustStart(code: u16) u8
{
    return @intCast(code - lengthCodeStart);
}

fn getLengthBitCount(code: u8) u6
{
    // const back = @as(u9, code) + lengthCodeStart;
    // switch (back)
    // {
    //     257 ... 264, 285 => return 0,
    //     265 ... 268 => return 1,
    //     269 ... 272 => return 2,
    //     273 ... 276 => return 3,
    //     277 ... 280 => return 4,
    //     281 ... 284 => return 5,
    //     else => unreachable,
    // }
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
    try testLengthBitCount(5, 283);
    try testLengthBitCount(5, 284);
    try testLengthBitCount(0, 285);
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

test "Length base length"
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
        0 ... 3 => 0,
        else => distanceCode / 2 - 1,
    };
}

fn testDistanceBitCount(expected: u16, code: u5) !void
{
    const expect = std.testing.expectEqual;
    try expect(expected, getDistanceBitCount(code));
}

test "Distance bit count"
{
    try testDistanceBitCount(0, 3);
    try testDistanceBitCount(5, 13);
    try testDistanceBitCount(13, 29);
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
    try testBaseDistance(4097, 24);
}
