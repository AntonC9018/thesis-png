const common = @import("common.zig");
const std = common.std;
const pipelines = common.pipelines;
const chunks = common.chunks;
const zlib = common.zlib;
const utils = common.utils;

pub const State = common.State;
pub const Context = common.Context;
pub const Action = common.Action;
pub const ChunkAction = common.ChunkAction;
pub const Chunk = common.Chunk;
pub const Settings = common.Settings;
pub const isStateTerminal = common.isParserStateTerminal;

const pngFileSignature = "\x89PNG\r\n\x1A\n";
fn validateSignature(slice: *pipelines.Sequence) !void 
{
    var copy = slice.*;
    pipelines.removeFront(&copy, pngFileSignature)
    catch |err| switch (err)
    {
        error.NoMatch => return error.SignatureMismatch,
        else => return err,
    };
    slice.* = copy;
}

pub fn printStepName(writer: anytype, parserState: *const State) !void
{
    switch (parserState.action)
    {
        .Signature => try writer.print("Signature", .{}),
        .Chunk =>
        {
            const chunk = &parserState.chunk;
            try writer.print("Chunk ", .{});
            switch (chunk.key)
            {
                .Length => try writer.print("Length", .{}),
                .ChunkType => try writer.print("Type", .{}),
                .Data =>
                {
                    try writer.print("Data ", .{});
                    // TODO:
                    // this probably needs some structure
                    // and I should solve this with reflection.
                    switch (chunk.object.type)
                    {
                        .ImageHeader =>
                        {
                            switch (chunk.dataState.imageHeader)
                            {
                                .Width => try writer.print("Width", .{}),
                                .Height => try writer.print("Height", .{}),
                                .BitDepth => try writer.print("BitDepth", .{}),
                                .ColorType => try writer.print("ColorType", .{}),
                                .CompressionMethod => try writer.print("CompressionMethod", .{}),
                                .FilterMethod => try writer.print("FilterMethod", .{}),
                                .InterlaceMethod => try writer.print("InterlaceMethod", .{}),
                                .Done => {},
                            }
                        },
                        .Palette =>
                        {
                            const byte = chunk.dataState.palette.bytesRead;
                            try writer.print("PLTE byte {x} (color index {}, state {})", .{
                                byte,
                                byte / 3,
                                chunk.dataState.palette.rgb,
                            });
                        },
                        .ImageData =>
                        {
                            const z = &parserState.imageData.zlib;
                            try printZlibState(z, writer);
                        },
                        else => |x| try writer.print("{any}", .{ x }),
                        // _ => try writer.print("?", .{}),
                    }
                },
                .CyclicRedundancyCheck => try writer.print("CyclicRedundancyCheck", .{}),
                .Done => {},
            }
        },
        .StartChunk => try writer.print("Chunk", .{}),
    }
    try writer.print("\n", .{});
}

fn printZlibState(z: *const zlib.State, writer: anytype) !void
{
    switch (z.action)
    {
        .CompressedData =>
        {
            const deflate = &z.decompressor.deflate;
            try writer.print("CompressedData {} ", .{ deflate.action });
            switch (deflate.action)
            {
                else => {},
                .BlockInit =>
                {
                    switch (deflate.blockState)
                    {
                        .DynamicHuffman => |dyn|
                        {
                            try writer.print("{any}", .{ dyn.codeDecoding });
                        },
                        else => {},
                    }
                },
                .DecompressionLoop =>
                {
                    switch (deflate.blockState)
                    {
                        .DynamicHuffman => |dyn|
                        {
                            try writer.print("dynamic {any}", .{ dyn.decompression });
                        },
                        .FixedHuffman => |fixed|
                        {
                            try writer.print("fixed: {any}", .{ fixed });
                            if (deflate.lastSymbol) |ls|
                            {
                                try writer.print("\nlast symbol: {any}", .{ ls });
                            }
                        },
                        else => try writer.print("{}", .{ deflate.blockState }),
                    }
                }
            }
        },
        else => |x| try writer.print("{}", .{ x }),
    }
}

fn debugPrintInfo(context: *const Context) !void
{
    if (!context.settings.logChunkStart)
    {
        return;
    }
    const outputStream = std.io.getStdOut().writer();
    try printStepName(outputStream, context.state);
    const offset = context.sequence.getStartBytePosition();
    try outputStream.print("Offset: {x}", .{ offset });

    {
        const z = &context.state.imageData.zlib;
        if (z.action == .CompressedData)
        {
            try outputStream.print(", Data bit offset: {d}", .{z.decompressor.deflate.bitOffset});
        }
    }
    try outputStream.print("\n", .{});

    const maxBytesToPrint = 10;
    const numBytesWillPrint = @min(context.sequence.len(), maxBytesToPrint);
    const s = context.sequence.sliceToExclusive(context.sequence.getPosition(numBytesWillPrint));
    if (s.len() > 0)
    {
        var iter = s.iterate().?;
        while (true)
        {
            for (iter.current()) |byte|
            {
                switch (byte)
                {
                    // ' ' ... '~' => try outputStream.print("{c} ", .{ byte }),
                    else => try outputStream.print("{X:0<2} ", .{ byte }),
                }
            }

            if (!iter.advance())
            {
                break;
            }
        }
        try outputStream.print("\n", .{});
    }
    try outputStream.print("\n", .{});
}

pub fn parseTopLevelItem(context: *const Context) !bool
{
    while (true)
    {
        try debugPrintInfo(context);

        const isDone = try parseNextItem(context);
        if (isDone)
        {
            return true;
        }
    }
}

pub fn parseNextItem(context: *const Context) !bool
{
    switch (context.state.action)
    {
        .Signature =>
        {
            try validateSignature(context.sequence);
            return true;
        },
        .StartChunk =>
        {
            if (context.sequence.isEmpty())
            {
                return error.NotEnoughBytes;
            }
            else
            {
                context.state.chunk = createChunkParserState();
                context.state.action = .Chunk;
            }
        },
        .Chunk =>
        {
            const isDone = try parseChunkItem(context);
            if (isDone)
            {
                return true;
            }
        },
    }
    return false;
}


pub fn parseChunkItem(context: *const Context) !bool
{
    const chunk = &context.state.chunk;
    switch (chunk.key)
    {
        .Length => 
        {
            const len = utils.readPngU32(context.sequence)
            catch
            {
                return error.LengthValueTooLarge;
            };

            chunk.object.dataByteLen = len;
            chunk.key = .ChunkType;
        },
        .ChunkType =>
        {
            if (context.sequence.len() < 4)
            {
                return error.NotEnoughBytes;
            }

            var chunkType: chunks.RawChunkType = undefined;

            const sequence_ = context.sequence;
            const chunkEndPosition = sequence_.getPosition(4);
            const o = sequence_.disect(chunkEndPosition);
            sequence_.* = o.right;

            o.left.copyTo(&chunkType.bytes);
            chunk.object.type = chunks.getKnownDataChunkType(chunkType);
            chunk.key = .Data;

            try chunks.initChunkDataNode(context, chunk.object.type);
        },
        .Data =>
        {
            const done = try chunks.parseChunkData(context);
            if (done)
            {
                chunk.key = .CyclicRedundancyCheck;
            }
        },
        .CyclicRedundancyCheck =>
        {
            // Just skip for now
            const value = try pipelines.readNetworkUnsigned(context.sequence, u32);
            chunk.object.crc = .{ .value = value };
            chunk.key = .Done;
        },
        .Done => unreachable,
    }
    return chunk.key == .Done;
}


pub fn createParserState() State
{
    return .{
        .chunk = createChunkParserState(),
    };
}

fn createChunkParserState() common.ChunkState
{
    return std.mem.zeroInit(common.ChunkState, .{
        .object = std.mem.zeroInit(common.Chunk, .{
            .data = .{ .none = {} },
        }),
        .dataState = .{ .none = {} },
    });
}
