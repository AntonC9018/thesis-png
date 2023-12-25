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

    var parserState = ParserState{};

    outerLoop: while (true)
    {
        var readResult = try reader.read();
        var context = ParserContext
        { 
            .state = &parserState,
            .sequence = &readResult.sequence,
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

            if (parserState.key != .Done)
            {
                std.debug.print("Ended in a non-terminal state.", .{});
            }

            break;
        }
        else if (parserState.key == .Done)
        {
            std.debug.print("Done, but not all input has been consumed.\n", .{});
        }

        try reader.advance(context.sequence.start());
    }

}

const ParserStateKey = enum 
{
    Signature,
    Done,
};

const ParserState = struct
{
    key: ParserStateKey = .Signature, 
};

const ParserContext = struct
{
    state: *ParserState,
    sequence: *p.Sequence,
};

fn doMaximumAmountOfParsing(context: *ParserContext) !void
{
    while (context.state.key != .Done)
    {
        try parseNextThing(context);
    }
}

fn parseNextThing(context: *ParserContext) !void
{
    switch (context.state.key)
    {
        .Signature => 
        {
            switch (validateSignature(context.sequence))
            {
                .NotEnoughBytes => return error.NotEnoughBytes,
                .NoMatch => return error.SignatureMismatch,
                .Removed => context.state.key = .Done,
            }
        },
        .Done => unreachable,
    }
}

const pngFileSignature = "\x89PNG\r\n\x1A\n";

const p = @import("pipelines.zig");
test { _ = p; }

fn validateSignature(slice: *p.Sequence) p.RemoveResult {
    const removeResult = slice.removeFront(pngFileSignature);
    return removeResult;
}

pub fn isByteOrderReversed() bool {
    return std.arch.endian == .little;
}

const ChunkTypeMetadataMask = struct {
    mask: ChunkType,
    
    pub fn ancillary() ChunkTypeMetadataMask {
        var result: ChunkType = {};
        result.bytes[0] = 0x20;
        return result;
    }
    pub fn private() ChunkTypeMetadataMask {
        var result: ChunkType = {};
        result.bytes[1] = 0x20;
        return result;
    }
    pub fn safeToCopy() ChunkTypeMetadataMask {
        var result: ChunkType = {};
        result.bytes[3] = 0x20;
        return result;
    }

    pub fn check(self: ChunkTypeMetadataMask, chunkType: ChunkType) bool {
        return (chunkType.value & self.mask.value) == self.mask.value;
    }
    pub fn set(self: ChunkTypeMetadataMask, chunkType: ChunkType) ChunkType {
        return ChunkType { .value = chunkType.value | self.mask.value, };
    }
    pub fn unset(self: ChunkTypeMetadataMask, chunkType: ChunkType) ChunkType {
        return ChunkType { .value = chunkType.value & (~self.mask.value), };
    }
};

const ChunkType = union {
    bytes: [4]u8,
    value: u32,
};

const ChunkHeader = struct {
    length: u32,
    chunkType: ChunkType,
};