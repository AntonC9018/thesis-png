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
        doMaximumAmountOfParsing(&context) catch |err|
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

            if (context.state.* != .CompletelyDone)
            {
                std.debug.print("Ended in a non-terminal state.", .{});
            }

            break;
        }
        else if (context.state.* == .CompletelyDone)
        {
            std.debug.print("Done, but not all input has been consumed.\n", .{});
        }

        try reader.advance(context.sequence.start());
    }

}

const ParserStateKey = enum 
{
    Signature,
    Chunk,
    CompletelyDone,
};

const ParserState = union(ParserStateKey)
{
    Signature: void,
    Chunk: ChunkParserState,
    CompletelyDone: void,
};

const ParserContext = struct
{
    state: *ParserState,
    sequence: *p.Sequence,
    allocator: std.mem.Allocator,
};

const ChunkParserStateKey = enum 
{
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
    byteLength: u31,
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

const ChunkParserState = struct
{
    key: ChunkParserStateKey = .Length,
    node: ChunkNode,
};

fn doMaximumAmountOfParsing(context: *ParserContext) !void
{
    while (context.state.* == .CompletelyDone)
    {
        try parseNextThing(context);
    }
}

fn parseNextThing(context: *ParserContext) !void
{
    switch (context.state.*)
    {
        .Signature => 
        {
            try validateSignature(context.sequence);
            context.state.* = .BeforeChunk;
        },
        .Chunk => |*state| {
            switch (state.key)
            {
                .Length => 
                {
                    const startOffset = context.sequence.getStartOffset();

                    const length = p.readNetworkU31(context.sequence)
                    catch |err| switch (err)
                    {
                        error.NumberTooLarge => return error.LengthTooLarge,
                        else => return err,
                    };

                    state.node.lengthNode = .{
                        .base = .{
                            .startPositionInFile = startOffset,
                            .byteLength = 4,
                        },
                        .byteLength = length,
                    };
                },
                .ChunkType =>
                {
                },
                else => return error.NotEnoughBytes,
            }
        },
        .CompletelyDone => unreachable,
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

fn validateSignature(slice: *p.Sequence) p.RemoveResult
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