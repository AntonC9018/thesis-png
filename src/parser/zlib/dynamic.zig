const helper = @import("helper.zig");
const huffman = helper.huffman;
const std = helper.std;

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

    tree: huffman.Tree,
    currentBitCount: u5,

    decodedLen: u5,
    repeatCount: u7,

    pub fn huffmanContext(self: *CodeFrequencyState) helper.HuffmanContext
    {
        return .{
            .tree = &self.tree,
            .currentBitCount = &self.currentBitCount,
        };
    }

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

    pub fn initArrayElement(context: *DeflateContext, self: *CodeDecodingState) !void
    {
        try helper.initState(context, &self.arrayElementInitialized);
    }

    pub fn getLiteralOrLenCodeCount(self: *const Self) usize
    {
        return @as(usize, self.literalOrLenCodeCount) + 257;
    }

    pub fn getLenCodeCount(self: *const Self) usize
    {
        return self.codeLenCodeCount + 4;
    }

    pub fn getDistanceCodeCount(self: *const Self) usize
    {
        return self.distanceCodeCount + 1;
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
    Distance,
};

const DecompressionState = struct
{
    distanceTree: huffman.Tree,
    literalOrLenTree: huffman.Tree,
    currentBitCount: u5,

    action: DecompressionAction,
    len: u5,
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
            try state.initArrayElement(context);

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

                // TODO: A semantic node for this? Or a higher level node?
                const tree = try huffman.createTree(
                    @ptrCast(&state.codeLenCodeLens),
                    context.allocator());
                state.codeFrequencyState = std.mem.zeroInit(CodeFrequencyState, .{
                    .action = .LiteralLen,
                    .tree = tree,
                });
            }
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
            state.literalOrLenCodeCount = len;

            std.debug.assert(len <= 18);

            try context.level().completeNodeWithValue(.{
                .Number = len,
            });
            
            // Value above 16 means the bits that follow are the repeat count.
            if (len >= 16)
            {
                freqState.action = .RepeatCount;

                if (readCount.* == 0)
                {
                    return error.NothingToRepeat;
                }

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
            const repeatCount = try helper.readNBits(context, repeatBitCount);
            freqState.repeatCount = @intCast(repeatCount);
            try context.level().completeNodeWithValue(.{
                .Number = repeatCount,
            });

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
    defer decodingState.deinit(allocator);

    const literalTree = try huffman.createTree(
        @ptrCast(decodingState.literalOrLenCodeLens),
        allocator);
    const distanceTree = try huffman.createTree(
        @ptrCast(decodingState.distanceCodeLens),
        allocator);

    state.* = .{
        .decompression = std.mem.zeroInit(DecompressionState, .{
            .literalOrLenTree = literalTree,
            .distanceTree = distanceTree,
        }),
    };
}

pub fn decompressSymbol(
    context: *DeflateContext,
    state: *DecompressionState) !?helper.Symbol
{
    try context.level().push();
    defer context.level().pop();

    switch (state.action)
    {
        .LiteralOrLen =>
        {
            const value = try helper.readAndDecodeCharacter(context, .{
                .tree = &state.literalOrLenTree,
                .currentBitCount = &state.currentBitCount,
            });
            var createNode = DecompressionNodeWriter
            {
                .context = context,
                .value = value,
            };

            switch (value)
            {
                // TODO: Share these constants with the fixed module.
                0 ... 255 =>
                {
                    try createNode.create(.Literal);
                    return .{ .LiteralValue = @intCast(value) };
                },
                256 =>
                {
                    try createNode.create(.EndBlock);
                    return .{ .EndBlock = { } };
                },
                257 ... 285 =>
                {
                    const len: u5 = @intCast(value - 257);
                    createNode.value_ = len;
                    try createNode.create(.Len);
                    state.action = .Distance;
                    state.len = len;
                },
                else => unreachable,
            }
        },
        .Distance =>
        {
            try context.level().setNodeType(.{
                .DynamicHuffman = .{
                    .Decompression = .Distance,
                },
            });
            const distance = try helper.readAndDecodeCharacter(context, .{
                .tree = &state.distanceTree,
                .currentBitCount = &state.currentBitCount,
            });
            state.action = .LiteralOrLen;
            try context.level().completeNodeWithValue(.{
                .Number = distance,
            });

            return .{
                .BackReference = .{
                    .distance = distance,
                    .len = state.len,
                }
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
};

pub const DecompressionNodeWriter = struct
{
    context: *DeflateContext,

    pub fn create(self: @This(), t: DecompressionValueType, value: usize) !void
    {
        try self.context.level().setNodeType(.{
            .DynamicHuffman = .{
                .DecompressionValue = t,
            },
        });
        try self.context.level().completeNodeWithValue(.{
            .Number = value,
        });
    }
};
