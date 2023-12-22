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
    var buffer = try reader.readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(buffer);

    var currentSlice = buffer;

    try validatePngFile(&currentSlice);
}

fn validatePngFile(currentSlice: *[]const u8) PngSignatureError!void {
    const pngFileSignature = "\x89PNG\r\n\x1A\n";
    if (currentSlice.len < pngFileSignature.len) {
        return error.FileTooShort;
    }
    const signatureSlice = currentSlice.*[0..pngFileSignature.len];
    const signatureMatched = std.mem.eql(u8, signatureSlice, pngFileSignature);
    if (!signatureMatched) {
        return error.SignatureMismatch;
    }

    currentSlice.* = currentSlice.*[pngFileSignature.len..];
}