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

    var allocator = std.heap.page_allocator;
    var reader = file.reader();
    const buffer = try reader.readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(buffer);

    const bufferObject = [_]p.Segment
    { 
        .{
            .array = buffer,
            .len = @intCast(buffer.len),
            .bytePosition = 0,
        },
    };
    var sequence = p.Sequence {
        .buffer = .{
            .segments = &bufferObject,
            .firstSegmentOffset = 0,
        },
        .range = .{
            .start = .{ .segment = 0, .offset = 0, },
            .end = .{ .segment = 0, .offset = @intCast(buffer.len), }
        },
    };
    switch (validateSignature(&sequence))
    {
        .NotEnoughBytes => return PngSignatureError.FileTooShort,
        .NoMatch => return PngSignatureError.SignatureMismatch,
        .Removed => {},
    }

    std.debug.print("Signature matched\n", .{});
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