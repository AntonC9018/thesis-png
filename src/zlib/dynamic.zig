const helper = @import("helper.zig");
const huffman = helper.huffman;
const std = helper.std;

const CodeDecodingAction = enum
{
    LiteralOrLenCodeCount,
    DistanceCodeCount,
    CodeLenCount,
    CodeLens,
    LiteralOrLenCodeLens,
    DistanceCodeLens,
    Done,
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
    action: CodeDecodingAction,

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

const DecompressionAction = enum
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
    context: *const helper.DeflateContext,
    state: *CodeDecodingState) !bool
{
    switch (state.action)
    {
        // TODO:
        // Maybe actually really try using async here?
        // Code like this kills me.
        .LiteralOrLenCodeCount =>
        {
            const count = try helper.readBits(.{ .context = context }, u5);
            state.literalOrLenCodeCount = count;
            state.action = .DistanceCodeCount;
            return false;
        },
        .DistanceCodeCount =>
        {
            const count = try helper.readBits(.{ .context = context }, u5);
            state.distanceCodeCount = count;
            state.action = .CodeLenCount;
            return false;
        },
        .CodeLenCount =>
        {
            const count = try helper.readBits(.{ .context = context }, u4);
            state.codeLenCodeCount = count;
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
            
            if (readAllArray)
            {
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

                    const tree = try huffman.createTree(
                        @ptrCast(&state.codeLenCodeLens),
                        context.allocator());
                    state.codeFrequencyState = std.mem.zeroInit(CodeFrequencyState, .{
                        .action = .LiteralLen,
                        .tree = tree,
                    });
                }
            }
            return false;
        },
        .LiteralOrLenCodeLens =>
        {
            const array = state.literalOrLenCodeLens;
            const readAllArray = try fullyReadCodeLenEncodedFrequency(context, state, array);

            if (readAllArray)
            {
                state.action = .DistanceCodeLens;
                state.distanceCodeLens = try context.allocator()
                    .alloc(u8, state.getDistanceCodeCount());
                state.readListItemCount = 0;
            }

            return false;
        },
        .DistanceCodeLens =>
        {
            const array = state.distanceCodeLens;
            const readAllArray = try fullyReadCodeLenEncodedFrequency(context, state, array);

            if (readAllArray)
            {
                state.action = .Done;
                return true;
            }

            return false;
        },
        .Done => unreachable,
    }
}

fn readCodeLenEncodedFrequency(
    context: *const helper.DeflateContext,
    state: *CodeDecodingState,
    outputArray: []u8) !bool
{
    const readCount = &state.readListItemCount;
    const freqState = &state.codeFrequencyState;

    switch (freqState.action)
    {
        .LiteralLen =>
        {
            const character = try helper.readAndDecodeCharacter(context, freqState.huffmanContext());
            const len: u5 = @intCast(character);
            state.literalOrLenCodeCount = len;

            std.debug.assert(len <= 18);

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

            freqState.action = .Done;
            outputArray[readCount.*] = len;
            readCount.* += 1;
            return true;
        },
        .RepeatCount =>
        {
            const repeatBitCount = freqState.repeatBitCount();
            const repeatCount = try helper.readNBits(context, repeatBitCount);
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

fn fullyReadCodeLenEncodedFrequency(
    context: *const helper.DeflateContext,
    state: *CodeDecodingState,
    outputArray: []u8) !bool
{
    const readCount = &state.readListItemCount;
    const freqState = &state.codeFrequencyState;
    if (readCount.* < outputArray.len)
    {
        while (true)
        {
            const done = try readCodeLenEncodedFrequency(context, state, outputArray);
            if (done)
            {
                freqState.action = .LiteralLen;
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

    const literalTree = try huffman.createTree(
        @ptrCast(decodingState.literalOrLenCodeLens),
        allocator);
    const distanceTree = try huffman.createTree(
        @ptrCast(decodingState.distanceCodeLens),
        allocator);

    // TODO:
    // Make sure this runs even on an errors.
    // There should be some sort of global dispose that works on any state.
    // NOTE: has to be done before tree creation, because we're using the arrays.
    decodingState.deinit(allocator);

    state.* = .{
        .decompression = std.mem.zeroInit(DecompressionState, .{
            .literalOrLenTree = literalTree,
            .distanceTree = distanceTree,
        }),
    };
}

pub fn decompressSymbol(
    context: *const helper.DeflateContext,
    state: *DecompressionState) !?helper.Symbol
{
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
                    return .{ .LiteralValue = @intCast(value) };
                },
                256 =>
                {
                    return .{ .EndBlock = { } };
                },
                257 ... 285 =>
                {
                    state.action = .Distance;
                    state.len = @intCast(value - 257);
                },
                else => unreachable,
            }
        },
        .Distance =>
        {
            const distance = try helper.readAndDecodeCharacter(context, .{
                .tree = &state.distanceTree,
                .currentBitCount = &state.currentBitCount,
            });
            state.action = .LiteralOrLen;

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
