const std = @import("std");

pub fn main() !void {
    var cwd = std.fs.cwd();

    var testDir = try cwd.openDir("test_data", .{ .access_sub_paths = true, });
    defer testDir.close();

    var file = try testDir.openFile("test.png", .{ .mode = .read_only, });
    defer file.close();

    const allocator = std.heap.page_allocator;
    var reader = p.Reader(@TypeOf(file.reader()))
    {
        .dataProvider = file.reader(),
        .allocator = allocator,
        .preferredBufferSize = 4096, // TODO: Get optimal block size from OS.
    };
    defer reader.deinit();

    var parserState: ParserState = .Signature;
    var chunks = std.ArrayList(ChunkNode).init(allocator);

    outerLoop: while (true)
    {
        var readResult = try reader.read();
        var context = ParserContext
        { 
            .state = &parserState,
            .sequence = &readResult.sequence,
            .allocator = allocator,
        };

        var isNonRecoverableError = false;
        doMaximumAmountOfParsing(&context, &chunks) catch |err|
        {
            switch (err)
            {
                error.NotEnoughBytes => 
                {
                    if (readResult.isEnd)
                    {
                        std.debug.print("File ended but expected more data\n", .{});
                        break :outerLoop;
                    }
                },
                error.SignatureMismatch => 
                {
                    std.debug.print("Signature mismatch\n", .{});
                },
                error.LengthTooLarge => 
                {
                    std.debug.print("Length too large\n", .{});
                },
                // else => std.debug.print("Some other error: {}\n", .{err}),
            }

            isNonRecoverableError = true;
        };

        if (isNonRecoverableError)
        {
            break;
        }

        if (readResult.isEnd)
        {
            const remaining = context.sequence.len();
            if (remaining > 0)
            {
                std.debug.print("Not all output consumed. Remaining length: {}\n", .{remaining});
            }

            if (!isDoneState(context.state.*))
            {
                std.debug.print("Ended in a non-terminal state.", .{});
            }

            break;
        }
        // else if (context.state.* == .CompletelyDone)
        // {
        //     std.debug.print("Done, but not all input has been consumed.\n", .{});
        // }

        try reader.advance(context.sequence.start());
    }
}

const DoneStateBit = 0x80;

const ParserStateKey = enum(u8) 
{
    Signature = 0,
    Chunk,

    ChunkDone = DoneStateBit,
    SignatureDone,
    // CompletelyDone,
};

const ParserState = union(ParserStateKey)
{
    Signature: void,
    Chunk: ChunkParserState,
    ChunkDone: void,
    SignatureDone: void,
    // CompletelyDone: void,
};

const ParserContext = struct
{
    state: *ParserState,
    sequence: *p.Sequence,
    allocator: std.mem.Allocator,
};

const ChunkParserStateKey = enum 
{
    // Length of the data field.
    Length,
    ChunkType,
    Data,
    CyclicRedundancyCheck,
};

const NodeBase = struct
{
    startPositionInFile: usize = 0,
    length: usize = 0,

    pub fn endPositionInFile(self: NodeBase) usize 
    {
        return self.startPositionInFile + self.length;
    }
};

const ChunkLengthNode = struct
{
    base: NodeBase,
    byteLength: u32,
};

const ChunkTypeNode = struct
{
    base: NodeBase,
    chunkType: ChunkType,
};

const ChunkDataNode = struct
{
    base: NodeBase,
    dataNodes: []union(enum) {
    },
};

const ChunkCyclicRedundancyCheckNode = struct
{
    base: NodeBase,
    crc: CyclicRedundancyCheck,
};

const CyclicRedundancyCheck = struct
{
    value: u32,
};

const ChunkNode = struct
{
    base: NodeBase,

    lengthNode: ChunkLengthNode = {},
    typeNode: ChunkTypeNode = {},
    dataNode: ChunkDataNode = {},
    crcNode: ChunkCyclicRedundancyCheckNode = {},
};

const SignatureNode = struct 
{
    base: NodeBase,
};

const TopLevelNode = union(enum) 
{
    signatureNode: SignatureNode,
    chunkNode: ChunkNode,

    pub fn base(self: TopLevelNode) NodeBase 
    {
        switch (self) 
        {
            inline else => |*n| return @as(*NodeBase, n), 
        }
    }
};


const ChunkParserState = struct
{
    key: ChunkParserStateKey = .Length,
    node: ChunkNode,
};

fn doMaximumAmountOfParsing(
    context: *ParserContext,
    nodes: *std.ArrayList(ChunkNode)) !void
{
    while (true)
    {
        try parseChunkOrSignature(context);

        switch (context.state.*)
        {
            .SignatureDone =>
            {
                // TODO: Signature node, and call a function with a TopLevelNode sort of tagged union.
                std.debug.print("Signature done\n", .{});
            },
            .ChunkDone =>
            {
                nodes.addOne(context.state.*.node);
            }
        }
    }
}

pub fn isDoneState(state: ParserStateKey) bool 
{
    return @intFromEnum(state) & DoneStateBit != 0;
}

fn parseChunkOrSignature(context: *ParserContext) !void
{
    while (true)
    {
        const stateTag: ParserStateKey = context.state.*;
        if (isDoneState(stateTag))
        {
            return;
        }

        try parseNextNode(context);
    }
}

fn parseNextNode(context: *ParserContext) !void
{
    switch (context.state.*)
    {
        .Signature =>
        {
            try validateSignature(context.sequence);
            context.state.* = .ChunkDone;
        },
        .ChunkDone, .SignatureDone => 
        {
            if (context.sequence.len() == 0)
            {
                return error.NotEnoughBytes;
            }
            else
            {
                // Reset the state.
                context.state.* = .{ .Chunk = std.mem.zeroes(@TypeOf(ChunkParserState)) };
                try parseChunkItem(context);
            }
        },
        .Chunk =>
        {
            try parseChunkItem(context);
        },
    }
}

fn parseChunkItem(context: *ParserContext) !void
{
    var state = &context.state.Chunk;
    switch (state.key)
    {
        .Length => 
        {
            const startOffset = context.sequence.getStartOffset();

            const length = try p.readNetworkU32(context.sequence);
            // The spec says it must not exceed 2^31
            if (length > 0x80000000)
            {
                return error.LengthTooLarge;
            }

            // TODO: 
            // Maybe not store these as nodes, cause that's kinda funny.
            // We can create these on demand since we know all the offsets.
            state.node.lengthNode = .{
                .base = .{
                    .startPositionInFile = startOffset,
                    .length = 4,
                },
                .byteLength = length,
            };
            state.key = .ChunkType;
        },
        .ChunkType =>
        {
            if (context.sequence.len() < 4)
            {
                return error.NotEnoughBytes;
            }

            var chunkType: ChunkType = undefined;
            const startOffset = context.sequence.getStartOffset();
            const chunkEndPosition = context.sequence.getPosition(4);
            context.sequence
                .sliceToExclusive(chunkEndPosition)
                .copyTo(&chunkType.bytes);

            state.node.typeNode = .{
                .base = .{
                    .startPositionInFile = startOffset,
                    .length = 4,
                },
                .chunkType = chunkType,
            };

            // Start the data node.
            state.node.dataNode.base = .{
                .startPositionInFile = startOffset,
                .length = 0,
            };
        },
        .Data =>
        {
            var dataNode = &state.node.dataNode;

            // Let's just skip for now.
            const totalDataBytes = state.node.lengthNode.byteLength;
            const remainingDataBytes = totalDataBytes - dataNode.base.length;
            if (remainingDataBytes > 0)
            {
                const skipBytesCount = @min(remainingDataBytes, context.sequence.len());
                dataNode.base.length += skipBytesCount;
                const newStart = context.sequence.getPosition(skipBytesCount);
                context.sequence.* = context.sequence.sliceFrom(newStart);
            }
            else
            {
                state.key = .CyclicRedundancyCheck;
                return;
            }

            if (dataNode.base.length == totalDataBytes)
            {
                state.key = .CyclicRedundancyCheck;
            }
        },
        .CyclicRedundancyCheck =>
        {
            // Just skip for now
            const startOffset = context.sequence.getStartOffset();
            const value = try p.readNetworkU32(context.sequence);
            state.node.crcNode = .{
                .base = .{
                    .startPositionInFile = startOffset,
                    .length = 4,
                },
                .crc = .{
                    .value = value,
                },
            };

            const chunkEndPosition = context.sequence.getPosition(4);
            context.sequence.* = context.sequence.sliceFrom(chunkEndPosition);
            context.state.* = .ChunkDone;
            return;
        },
    }
}

pub fn initChunkParserState(context: *ParserContext) void 
{
    context.state.* = ChunkParserState
    {
        .node = ChunkNode
        {
            .base = NodeBase
            {
                .startPositionInFile = context.sequence.getStartOffset(),
            },
        },
    };
}

const pngFileSignature = "\x89PNG\r\n\x1A\n";

const p = @import("pipelines.zig");
test { _ = p; }

fn validateSignature(slice: *p.Sequence) !void 
{
    p.removeFront(slice, pngFileSignature)
    catch |err| switch (err)
    {
        error.NoMatch => return error.SignatureMismatch,
        else => return err,
    };
}

const ChunkTypeMetadataMask = struct 
{
    mask: ChunkType,
    
    pub fn ancillary() ChunkTypeMetadataMask 
    {
        var result: ChunkType = {};
        result.bytes[0] = 0x20;
        return result;
    }
    pub fn private() ChunkTypeMetadataMask 
    {
        var result: ChunkType = {};
        result.bytes[1] = 0x20;
        return result;
    }
    pub fn safeToCopy() ChunkTypeMetadataMask 
    {
        var result: ChunkType = {};
        result.bytes[3] = 0x20;
        return result;
    }

    pub fn check(self: ChunkTypeMetadataMask, chunkType: ChunkType) bool 
    {
        return (chunkType.value & self.mask.value) == self.mask.value;
    }
    pub fn set(self: ChunkTypeMetadataMask, chunkType: ChunkType) ChunkType 
    {
        return ChunkType { .value = chunkType.value | self.mask.value, };
    }
    pub fn unset(self: ChunkTypeMetadataMask, chunkType: ChunkType) ChunkType 
    {
        return ChunkType { .value = chunkType.value & (~self.mask.value), };
    }
};

const ChunkType = union 
{
    bytes: [4]u8,
    value: u32,
};

const ChunkHeader = struct 
{
    length: u32,
    chunkType: ChunkType,
};