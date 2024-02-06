const std = @import("std");

pub fn main() !void
{
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

    while (true) outerLoop:
    {
        var readResult = try reader.read();
        var context = ParserContext
        { 
            .state = &parserState,
            .sequence = &readResult.sequence,
            .allocator = allocator,
        };

        doMaximumAmountOfParsing(&context, &chunks)
        catch |err|
        {
            const isNonRecoverableError = e:
            {
                switch (err)
                {
                    error.NotEnoughBytes => break :e false,
                    error.SignatureMismatch => 
                    {
                        std.debug.print("Signature mismatch\n", .{});
                        break :e true;
                    },
                    error.LengthTooLarge => 
                    {
                        std.debug.print("Length too large\n", .{});
                        break :e true;
                    },
                    else => |_| 
                    {
                        std.debug.print("Some other error: {}\n", .{err});
                        break :e true;
                    },
                }
            };

            if (isNonRecoverableError)
            {
                break :outerLoop;
            }
        };

        if (readResult.isEnd)
        {
            const remaining = context.sequence.len();
            if (remaining > 0)
            {
                std.debug.print("Not all output consumed. Remaining length: {}\n", .{remaining});
            }

            if (!isParserStateTerminal(context.state))
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

    for (chunks.items) |*chunk| 
    {
        std.debug.print("Chunk(Length: {d}, Type: {s}, CRC: {d})\n", .{
            chunk.byteLength,
            chunk.chunkType.bytes,
            chunk.crc.value,
        });
    }
}

// What is the next expected type?
const ParserAction = enum(u8) 
{
    Signature = 0,
    StartChunk,
    Chunk,
};

const ParserState = union(ParserAction)
{
    Signature: void,
    StartChunk: void,
    Chunk: ChunkParserState,
};

pub fn isParserStateTerminal(state: *const ParserState) bool 
{
    return state.* == .StartChunk;
}

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
    Done,
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
    data: union
    { 
        idhr: IHDR,
        none: void,
    },
};

const IHDR = struct
{
    width: u32,
    heigth: u32,
    bitDepth: BitDepth,
    colorType: ColorType,
    compressionMethod: CompressionMethod,
    filterMethod: FilterMethod,
    interlaceMethod: InterlaceMethod,
};

const BitDepth = u8;

const ColorType = struct
{
    flags: u8,

    const PalleteUsed = 1 << 0;
    const ColorUsed = 1 << 1;
    const AlphaChannelUsed = 1 << 2;

    pub fn palleteUsed(self: ColorType) bool
    {
        return (self.flags & PalleteUsed) != 0;
    }
    pub fn colorUsed(self: ColorType) bool
    {
        return (self.flags & ColorUsed) != 0;
    }
    pub fn alphaChannelUsed(self: ColorType) bool
    {
        return (self.flags & AlphaChannelUsed) != 0;
    }
};

pub fn isBitDepthValid(bitDepth: BitDepth) bool
{
    return contains(&[_]u8{ 1, 2, 4, 8, 16 }, bitDepth);
}

pub fn isColorTypeValid(colorType: ColorType) bool
{
    return contains(&[_]u8{ 
        0,
        ColorType.ColorUsed,
        ColorType.ColorUsed | ColorType.PalleteUsed,
        ColorType.AlphaChannelUsed,
        ColorType.ColorUsed | ColorType.AlphaChannelUsed,
    }, colorType.flags);
}

pub fn isColorTypeAllowedForBitDepth(
    bitDepth: BitDepth,
    colorType: ColorType) bool
{
    const allowedValues = switch (colorType.flags)
    {
        // Each pixel is a grayscale sample.
        0 => &[_]u8{ 1, 2, 4, 8, 16 },

        // Each pixel is an R, G, B triple.
        ColorType.ColorUsed => &[_]u8{ 8, 16 },

        // Each pixel is a palette index; a PLTE chunk must appear.
        ColorType.ColorUsed | ColorType.PalleteUsed => &[_]u8{ 1, 2, 4, 8 },

        // Each pixel is a grayscale sample, followed by an alpha sample.
        ColorType.AlphaChannelUsed => &[_]u8{ 8, 16 },

        // Each pixel is an R, G, B triple, followed by an alpha sample.
        ColorType.ColorUsed | ColorType.AlphaChannelUsed => &[_]u8{ 8, 16 },

        else => false,
    };
    return contains(allowedValues, bitDepth);
}

pub fn getSampleDepth(idhr: IHDR) u8
{
    return switch (idhr.colorType.flags)
    {
        ColorType.ColorUsed | ColorType.PalleteUsed => 8,
        else => idhr.bitDepth,
    };
}

const CompressionMethod = u8;

pub fn isCompressionMethodValid(compressionMethod: CompressionMethod) bool
{
    return compressionMethod == 0;
}

const FilterMethod = u8;

pub fn isFilterMethodValid(filterMethod: FilterMethod) bool
{
    return filterMethod == 0;
}

const InterlaceMethod = enum(u8)
{
    None = 0,
    Adam7 = 1,
    _,
};

pub fn contains(arr: []const u8, value: u8) bool
{
    for (arr) |item|
    {
        if (item == value)
        {
            return true;
        }
    }
    return false;
}

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
    byteLength: u32,
    chunkType: ChunkType,
    dataNode: ChunkDataNode,
    crc: CyclicRedundancyCheck,
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
    dataNode: DataNodeParserState,
};

const DataNodeParserState = union
{
    idhr: IDHRParserStateKey,
    bytesSkipped: u32,
};

const IDHRParserStateKey = enum
{
    Width,
    Height,
    BitDepth,
    ColorType,
    CompressionMethod,
    FilterMethod,
    InterlaceMethod,
    Done,
};

fn doMaximumAmountOfParsing(
    context: *ParserContext,
    nodes: *std.ArrayList(ChunkNode)) !void
{
    while (true)
    {
        const isDone = try parseTopLevelNode(context);
        if (!isDone)
        {
            continue;
        }

        switch (context.state.*)
        {
            .Signature => 
            {
                std.debug.print("Signature\n", .{});
            },
            .Chunk =>
            {
                const newItem = try nodes.addOne();
                newItem.* = context.state.Chunk.node;
            },
            .StartChunk => unreachable,
        }

        context.state.* = .StartChunk;
    }
}

fn parseTopLevelNode(context: *ParserContext) !bool
{
    while (true)
    {
        const isDone = try parseNextNode(context);
        if (isDone)
        {
            return true;
        }
    }
}

fn parseNextNode(context: *ParserContext) !bool
{
    switch (context.state.*)
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
                initChunkParserState(context);
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

fn readPngU32(sequence: *p.Sequence) !u32
{
    const value = try p.readNetworkU32(sequence);
    if (value > 0x80000000)
    {
        return error.UnsignedValueTooLarge;
    }
    return value;
}

fn parseChunkItem(context: *ParserContext) !bool
{
    var state = &context.state.Chunk;
    switch (state.key)
    {
        .Length => 
        {
            const length = try p.readNetworkU32(context.sequence);
            // The spec says it must not exceed 2^31
            if (length > 0x80000000)
            {
                return error.LengthTooLarge;
            }

            state.node.byteLength = length;
            state.key = .ChunkType;
        },
        .ChunkType =>
        {
            if (context.sequence.len() < 4)
            {
                return error.NotEnoughBytes;
            }

            var chunkType: ChunkType = undefined;

            const sequence_ = context.sequence;
            const chunkEndPosition = sequence_.getPosition(4);
            const o = sequence_.disect(chunkEndPosition);
            sequence_.* = o.right;

            o.left.copyTo(&chunkType.bytes);
            state.node.chunkType = chunkType;
            state.key = .Data;

            state.node.dataNode.base = .{
                .startPositionInFile = o.right.getStartOffset(),
                .length = state.node.byteLength,
            };

            switch (chunkType.bytes)
            {
                KnownDataChunkType.IDHR =>
                {
                    state.dataNode = .idhr;
                    state.node.dataNode.data = .idhr;
                },
                else =>
                {
                    state.dataNode = .bytesSkipped;
                    state.node.dataNode.data = .none;
                },
            }
        },
        .Data =>
        {
            var dataNode = &state.node.dataNode;

            const done = done:
            {
                switch (state.node.chunkType.bytes)
                {
                    KnownDataChunkType.IDHR =>
                    {
                        const idhrStateKey = &state.dataNode.idhr;
                        const idhr = &dataNode.data.idhr;
                        switch (idhrStateKey)
                        {
                            .Width => 
                            {
                                const value = try readPngU32(context.sequence);
                                idhr.width = value;
                                idhrStateKey.* = .Height;
                            },
                            .Heigth =>
                            {
                                const value = try readPngU32(context.sequence);
                                idhr.height = value;
                                idhrStateKey.* = .BitDepth;
                            },
                            .BitDepth =>
                            {
                                const value = try p.removeFirst(context.sequence);
                                idhr.bitDepth = .{ .value = value };
                                if (!isBitDepthValid(value))
                                {
                                    return error.InvalidBitDepth;
                                }
                                idhrStateKey.* = .ColorType;
                            },
                            .ColorType =>
                            {
                                const value = try p.removeFirst(context.sequence);
                                idhr.colorType = .{ .flags = value };
                                if (!isColorTypeValid(value))
                                {
                                    return error.InvalidColorType;
                                }
                                if (!isColorTypeAllowedForBitDepth(value, idhr.bitDepth.value))
                                {
                                    return error.ColorTypeNotAllowedForBitDepth;
                                }
                                idhrStateKey.* = .CompressionMethod;
                            },
                            .CompressionMethod =>
                            {
                                const value = try p.removeFirst(context.sequence);
                                idhr.compressionMethod = value;
                                if (!isCompressionMethodValid(value))
                                {
                                    return error.InvalidCompressionMethod;
                                }
                                idhrStateKey.* = .FilterMethod;
                            },
                            .FilterMethod =>
                            {
                                const value = try p.removeFirst(context.sequence);
                                idhr.filterMethod = value;
                                if (!isFilterMethodValid(value))
                                {
                                    return error.InvalidFilterMethod;
                                }
                                idhrStateKey.* = .InterlaceMethod;
                            },
                            .InterlaceMethod =>
                            {
                                const value = try p.removeFirst(context.sequence);
                                const enumValue: InterlaceMethod = @enumFromInt(value);
                                idhr.interlaceMethod = enumValue;
                                switch (enumValue)
                                {
                                    .None, .Adam7 => {},
                                    _ => return error.InvalidInterlaceMethod,
                                }
                                idhrStateKey.* = .Done;
                                break :done true;
                            },
                            .Done => unreachable,
                        }
                        break :done false;
                    },
                    // Let's just skip for now.
                    else =>
                    {
                        const bytesSkipped = &state.dataNode.bytesSkipped;
                        const totalBytes = state.node.byteLength;
                        if (bytesSkipped.* < totalBytes)
                        {
                            const bytesToSkip = totalBytes - bytesSkipped.*;
                            const skipBytesCount = @min(bytesToSkip, context.sequence.len());
                            bytesSkipped.* += skipBytesCount;
                            const newStart = context.sequence.getPosition(skipBytesCount);
                            context.sequence.* = context.sequence.sliceFrom(newStart);
                        }

                        break :done (bytesSkipped.* == totalBytes);
                    }
                }
            };

            if (done)
            {
                state.key = .CyclicRedundancyCheck;
                return true;
            }
        },
        .CyclicRedundancyCheck =>
        {
            // Just skip for now
            const value = try p.readNetworkU32(context.sequence);
            state.node.crc = .{ .value = value };
            state.key = .Done;
        },
        .Done => unreachable,
    }
    return state.key == .Done;
}

pub fn initChunkParserState(context: *ParserContext) void 
{
    context.state.* = 
    .{
        .Chunk = std.mem.zeroInit(ChunkParserState,
        .{
            .node = std.mem.zeroInit(ChunkNode,
            .{
                .base = NodeBase
                {
                    .startPositionInFile = context.sequence.getStartOffset(),
                },
            }),
        })
    };
}

const pngFileSignature = "\x89PNG\r\n\x1A\n";

const p = @import("pipelines.zig");
test { _ = p; }

fn validateSignature(slice: *p.Sequence) !void 
{
    var copy = slice.*;
    p.removeFront(&copy, pngFileSignature)
    catch |err| switch (err)
    {
        error.NoMatch => return error.SignatureMismatch,
        else => return err,
    };
    slice.* = copy;
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

const ChunkType = extern union 
{
    bytes: [4]u8,
    value: u32,
};

const ChunkHeader = struct 
{
    length: u32,
    chunkType: ChunkType,
};

const KnownDataChunkType = enum(u8[4])
{
    IDHR = &"IDHR",
    PLTE = &"PLTE",
};
