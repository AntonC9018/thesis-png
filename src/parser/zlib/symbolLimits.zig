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
