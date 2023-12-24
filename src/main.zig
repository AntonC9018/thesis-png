const std = @import("std");

const PngSignatureError = error {
    FileTooShort,
    SignatureMismatch,
};

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

    const State = enum {
        Signature,
        Done,
    };
    var readState = struct {
        state: State = .Signature,
    }{};

    outerLoop: while (true)
    {
        const readResult = try reader.read();
        var sequence = readResult.sequence;

        const maybeParseError = (while (true) inner:
        {
            switch (readState.state)
            {
                .Signature => 
                {
                    switch (validateSignature(&sequence))
                    {
                        .NotEnoughBytes => break :inner error.NotEnoughBytes,
                        .Removed => readState.state = .Done,
                        .NoMatch => break :inner error.SignatureMismatch,
                    }
                },
                .Done => break,
            }
        } else null);

        if (maybeParseError) |parseError|
        {
            switch (parseError)
            {
                error.NotEnoughBytes => 
                {
                    if (readResult.isEnd)
                    {
                        std.debug.print("File ended but expected more data\n", .{});
                        break :outerLoop;
                    }
                },
                error.SignatureMismatch => std.debug.print("Signature mismatch\n", .{}),
                // else => std.debug.print("Some other error: {}\n", .{err}),
            }
        }

        if (readResult.isEnd)
        {
            const remaining = sequence.len();
            if (remaining > 0)
            {
                std.debug.print("Not all output consumed. Remaining length: {}\n", .{remaining});
            }

            break;
        }

        try reader.advance(sequence);
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