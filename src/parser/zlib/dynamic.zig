const helper = @import("helper.zig");
const huffman = helper.huffman;
const std = helper.std;
const symbolLimits = helper.symbolLimits;

const DeflateContext = helper.DeflateContext;

pub const CodeDecodingAction = enum
{
    LiteralOrLenCodeCount,
    DistanceCodeCount,
    CodeLenCount,
    CodeLens,
    LiteralOrLenCodeLens,
    DistanceCodeLens,
};

pub const CodeFrequencyAction = enum
{
    LiteralLen,
    RepeatCount,
};

const CodeFrequencyState = struct
{
    action: CodeFrequencyAction = .LiteralLen,

    decodedLen: u5,
    tree: huffman.Tree,
    currentBitCount: u5,

    pub fn huffmanContext(self: *CodeFrequencyState) helper.HuffmanContext
    {
        return .{
            .tree = &self.tree,
            .currentBitCount = &self.currentBitCount,
        };
    }

    pub fn repeatBitCount(self: CodeFrequencyState) u5
    {
        return switch (self.decodedLen)
        {
            16 => 2,
            17 => 3,
            18 => 7,
            else => unreachable,
        };
    }

    pub fn baseRepeatCount(self: CodeFrequencyState) u5
    {
        return switch (self.decodedLen)
        {
            16 => 3,
            17 => 3,
            18 => 11,
            else => unreachable,
        };
    }
};

pub const State = union
{
    codeDecoding: CodeDecodingState,
    decompression: DecompressionState,
};

pub const CodeDecodingState = struct
{
    action: CodeDecodingAction = .LiteralOrLenCodeCount,

    // Reset as it's being read.
    readListItemCount: usize,
    codeFrequencyState: CodeFrequencyState,

    literalOrLenCodeCount: u5,
    codeLenCodeCount: u4,
    distanceCodeCount: u5,

    codeLenCodeLens: [19]u3,
    literalOrLenCodeLens: []u8,
    distanceCodeLens: []u8,

    const Self = @This();

    pub fn getLiteralOrLenCodeCount(self: *const Self) usize
    {
        return @as(usize, self.literalOrLenCodeCount) + 257;
    }

    pub fn getLenCodeCount(self: *const Self) usize
    {
        return @as(usize, self.codeLenCodeCount) + 4;
    }

    pub fn getDistanceCodeCount(self: *const Self) usize
    {
        return @as(usize, self.distanceCodeCount) + 1;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void
    {
        self.codeFrequencyState.tree.deinit(allocator);
        allocator.free(self.literalOrLenCodeLens);
        allocator.free(self.distanceCodeLens);
    }
};

pub const DecompressionAction = enum
{
    LiteralOrLen,
    LenExtraBits,
    DistanceCode,
    DistanceExtraBits,
};

const DecompressionState = struct
{
    distanceTree: huffman.Tree,
    literalOrLenTree: huffman.Tree,
    currentBitCount: u5,

    action: DecompressionAction,
    lenCode: symbolLimits.LenCode,
    len: symbolLimits.Len,
    distanceCode: symbolLimits.DistanceCode,
};

pub fn decodeCodes(
    context: *DeflateContext,
    state: *CodeDecodingState) !bool
{
    try context.level().pushNode(.{
        .DynamicHuffman = .{
            .CodeDecoding = state.action,
        },
    });
    defer context.level().pop();

    switch (state.action)
    {
        .LiteralOrLenCodeCount =>
        {
            const count = try helper.readBits(.{ .context = context }, u5);
            state.literalOrLenCodeCount = count;
            try context.level().completeNodeWithValue(.{
                .Number = count,
            });
            state.action = .DistanceCodeCount;
            return false;
        },
        .DistanceCodeCount =>
        {
            const count = try helper.readBits(.{ .context = context }, u5);
            state.distanceCodeCount = count;
            try context.level().completeNodeWithValue(.{
                .Number = count,
            });
            state.action = .CodeLenCount;
            return false;
        },
        .CodeLenCount =>
        {
            const count = try helper.readBits(.{ .context = context }, u4);
            state.codeLenCodeCount = count;
            try context.level().completeNodeWithValue(.{
                .Number = count,
            });
            state.action = .CodeLens;
            return false;
        },
        .CodeLens =>
        {
            const readAllArray = try helper.readArrayElement(
                context,
                state.codeLenCodeLens[0 .. state.getLenCodeCount()],
                &state.readListItemCount,
                3);
            
            if (!readAllArray)
            {
                return false;
            }

            // TODO: Maybe a node for each code?
            try context.level().completeNode();

            state.action = .LiteralOrLenCodeLens;
            state.literalOrLenCodeLens = try context.allocator()
                .alloc(u8, state.getLiteralOrLenCodeCount());

            const copy = state.codeLenCodeLens;
            @memset(&state.codeLenCodeLens, 0);
            for (0 .. state.getLenCodeCount()) |i|
            {
                const orderArray = &[_]u5{
                    16, 17, 18, 0, 8,
                    7, 9, 6, 10, 5,
                    11, 4, 12, 3, 13,
                    2, 14, 1, 15,
                };
                const remappedIndex = orderArray[i];
                state.codeLenCodeLens[remappedIndex] = copy[i];
            }

            // TODO: A semantic node for this? Or a higher level node?
            const tree = try huffman.createTree(
                @ptrCast(&state.codeLenCodeLens),
                context.allocator());
            state.codeFrequencyState = std.mem.zeroInit(CodeFrequencyState, .{
                .action = .LiteralLen,
                .tree = tree,
            });

            return false;
        },
        .LiteralOrLenCodeLens =>
        {
            const array = state.literalOrLenCodeLens;
            const readAllArray = try fullyReadCodeLenEncodedFrequency(context, state, array);

            if (!readAllArray)
            {
                return false;
            }

            state.action = .DistanceCodeLens;
            state.distanceCodeLens = try context.allocator()
                .alloc(u8, state.getDistanceCodeCount());
            state.readListItemCount = 0;

            try context.level().completeNode();
            return false;
        },
        .DistanceCodeLens =>
        {
            const array = state.distanceCodeLens;
            const readAllArray = try fullyReadCodeLenEncodedFrequency(context, state, array);

            if (readAllArray)
            {
                try context.level().completeNode();
                return true;
            }

            return false;
        },
    }
}

fn readCodeLenEncodedFrequency(
    context: *DeflateContext,
    state: *CodeDecodingState,
    outputArray: []u8) !bool
{
    const readCount = &state.readListItemCount;
    const freqState = &state.codeFrequencyState;

    try context.level().pushNode(.{
        .DynamicHuffman = .{
            .CodeFrequency = freqState.action,
        },
    });
    defer context.level().pop();

    switch (freqState.action)
    {
        .LiteralLen =>
        {
            const character = try helper.readAndDecodeCharacter(context, freqState.huffmanContext());
            const len: u5 = @intCast(character);

            std.debug.assert(len <= 18);

            try context.level().completeNodeWithValue(.{
                .Number = len,
            });
            
            if (len >= 16)
            {
                freqState.action = .RepeatCount;
                freqState.decodedLen = len;
                return false;
            }
            else
            {
                outputArray[readCount.*] = len;
                readCount.* += 1;
                return true;
            }
        },
        .RepeatCount =>
        {
            const repeatBitCount = freqState.repeatBitCount();
            const value = try helper.readNBits(context, repeatBitCount);

            try context.level().completeNodeWithValue(.{
                .Number = value,
            });

            const repeatCount = freqState.baseRepeatCount() + value;
            const maxCanReadCount = outputArray.len - readCount.*;
            if (repeatCount > maxCanReadCount)
            {
                return error.InvalidRepeatCount;
            }

            for (0 .. repeatCount) |i|
            {
                const index = readCount.* + i;
                outputArray[index] = 0;
            }
            readCount.* += repeatCount;
            return true;
        },
    }
}

fn fullyReadCodeLenEncodedFrequency(
    context: *DeflateContext,
    state: *CodeDecodingState,
    outputArray: []u8) !bool
{
    const readCount = &state.readListItemCount;
    const freqState = &state.codeFrequencyState;

    if (readCount.* < outputArray.len)
    {
        while (true)
        {
            try context.level().pushNode(.{
                .DynamicHuffman = .EncodedFrequency,
            });
            defer context.level().pop();

            const done = try readCodeLenEncodedFrequency(context, state, outputArray);
            if (done)
            {
                freqState.action = .LiteralLen;
                try context.level().completeNode();
                break;
            }
        }
    }

    std.debug.print("Read count is now at {}\n", .{ readCount.* });

    return readCount.* == outputArray.len;
}


pub fn initializeDecompressionState(
    state: *State,
    allocator: std.mem.Allocator) !void
{
    const decodingState = &state.codeDecoding;
    // TODO:
    // Make sure this runs even on errors.
    // There should be some sort of global dispose that works on any state.
    // NOTE: has to be done before tree creation, because we're using the arrays.
    const decompressionState = result:
    {
        defer decodingState.deinit(allocator);

        const literalTree = try huffman.createTree(
            @ptrCast(decodingState.literalOrLenCodeLens),
            allocator);
        const distanceTree = try huffman.createTree(
            @ptrCast(decodingState.distanceCodeLens),
            allocator);
        break :result std.mem.zeroInit(DecompressionState, .{
            .literalOrLenTree = literalTree,
            .distanceTree = distanceTree,
        });
    };

    state.* = .{
        .decompression = decompressionState,
    };
}

pub fn decompressSymbol(
    context: *DeflateContext,
    state: *DecompressionState) !?helper.Symbol
{
    try context.level().push();
    defer context.level().pop();

    var createNode = helper.DecompressionNodeWriter
    {
        .context = context,
    };

    switch (state.action)
    {
        .LiteralOrLen =>
        {
            const value = try helper.readAndDecodeCharacter(context, .{
                .tree = &state.literalOrLenTree,
                .currentBitCount = &state.currentBitCount,
            });

            switch (value)
            {
                // TODO: Share these constants with the fixed module.
                0 ... 255 =>
                {
                    try createNode.create(.Literal, value);
                    return .{ .LiteralValue = @intCast(value) };
                },
                256 =>
                {
                    try createNode.create(.EndBlock, value);
                    return .{ .EndBlock = { } };
                },
                257 ... 285 =>
                {
                    state.action = .LenExtraBits;
                    state.lenCode = symbolLimits.LenCode.fromUnadjustedCode(@intCast(value));
                    try createNode.create(.Len, @intFromEnum(state.lenCode));
                    return null;
                },
                else => unreachable,
            }
        },
        .LenExtraBits =>
        {
            const len = switch (state.lenCode.extraBitCount())
            {
                0 => 0,
                else => |x| try helper.readNBits(context, x),
            };
            const computedLen = state.lenCode.base() + @as(symbolLimits.Len, @intCast(len));
            state.action = .DistanceCode;
            state.len = computedLen;

            try createNode.create(.LenCodeExtra, len);
            return null;
        },
        .DistanceCode =>
        {
            const distance = try helper.readAndDecodeCharacter(context, .{
                .tree = &state.distanceTree,
                .currentBitCount = &state.currentBitCount,
            });
            state.action = .DistanceExtraBits;
            state.distanceCode = @enumFromInt(distance);

            try createNode.create(.Distance, distance);
            return null;
        },
        .DistanceExtraBits =>
        {
            const distance = switch (state.distanceCode.extraBitCount())
            {
                0 => 0,
                else => |x| try helper.readNBits(context, x),
            };
            state.action = .LiteralOrLen;
            try createNode.create(.DistanceExtra, distance);
            return .{
                .BackReference = .{
                    .distance = state.distanceCode.base() + @as(symbolLimits.Distance, @intCast(distance)),
                    .len = state.len,
                },
            };
        },
    }
}
