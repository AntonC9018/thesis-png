const common = @import("common.zig");
const std = common.std;
const pipelines = common.pipelines;
pub const chunks = common.chunks;
const zlib = common.zlib;
const utils = common.utils;

pub const State = common.State;
pub const Context = common.Context;
pub const Action = common.TopLevelAction;
pub const ChunkAction = common.ChunkAction;
pub const Chunk = common.Chunk;
pub const Settings = common.Settings;
pub const ChunkType = chunks.ChunkType;
pub const isStateTerminal = common.isParserStateTerminal;
pub const CyclicRedundancyCheck = common.CyclicRedundancyCheck;
pub const ColorType = chunks.ColorType;

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

fn debugPrintInfo(context: *Context) !void
{
    if (!context.settings().logChunkStart)
    {
        return;
    }
    const outputStream = std.io.getStdOut().writer();
    {
        const nodeContext = context.nodeContext();
        for (0 .., nodeContext.syntaxNodeStack.items) |i, it|
        {
            try outputStream.print("({})", .{ it.nodeType });
            if (i != 0)
            {
                try outputStream.print(" -> ", .{});
            }
        }
        try outputStream.print("\n", .{});
    }
    const offset = context.sequence().getStartBytePosition();
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
    const numBytesWillPrint = @min(context.sequence().len(), maxBytesToPrint);
    const s = context.sequence().sliceToExclusive(context.sequence().getPosition(numBytesWillPrint));
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

pub fn parseTopLevelItem(context: *Context) !bool
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

const TopLevelInitializer = struct
{
    context: *Context,

    pub fn execute(self: @This()) !void
    {
        const action = self.context.state.action;
        self.context.level().setNodeType(.{ .TopLevel = action });

        switch (action)
        {
            .Signature => {},
            .Chunk =>
            {
                self.context.state.chunk = createChunkParserState();
            },
        }
    }
};

pub fn parseNextItem(context: *Context) !bool
{
    try context.level().pushInit(TopLevelInitializer
    {
        .context = context,
    });
    defer context.level().pop();

    try debugPrintInfo(context);

    const action = &context.state.action;
    switch (action.*)
    {
        .Signature =>
        {
            try validateSignature(context.sequence());
            try context.level().completeNodeWithValue(.{
                .LiteralString = pngFileSignature,
            });
            action.* = .Chunk;
            return true;
        },
        .Chunk =>
        {
            const isDone = try parseChunkItem(context);
            if (isDone)
            {
                try context.level().completeNode();
                return true;
            }
        },
    }
    return false;
}

const ChunkItemNodeInitializer = struct
{
    context: *Context,

    pub fn execute(self: ChunkItemNodeInitializer) !void
    {
        const state = self.context.state.chunk;

        self.context.level().setNodeType(.{
            .Chunk = state.action,
        });

        switch (state.action)
        {
            .Data =>
            {
                const chunkType = state.object.type;
                try chunks.initChunkDataNode(self.context, chunkType);

                if (chunkType == .ImageData)
                {
                    const dataId = &self.context.state.imageData.dataId;
                    if (dataId.* != common.ast.invalidNodeDataId)
                    {
                        try self.context.level().setSemanticParent(dataId.*);
                    }

                    dataId.* = self.context.level().getNodeId();
                }
            },
            else => {},
        }
    }
};

const SliceHelper = struct
{
    // NOTE:
    // Could generalize it a little (take the sizes as parameters,
    // write to the context through an interface, etc),
    // but there's no point currently.
    context: *Context,
    initialSequencePtr: *pipelines.Sequence,
    sequence: pipelines.Sequence,
    initialLen: u32,
    isLast: bool,

    fn create(context: *Context) SliceHelper
    {
        const chunk = &context.state.chunk;
        const s = context.sequence();
        const allLen = s.len();
        const chunkLen = chunk.object.dataByteLen;
        const leftToRead = chunkLen - chunk.bytesRead;
        const readLen = @min(leftToRead, allLen);
        const isLastChunkDataRead = allLen >= leftToRead;
        const newSequence = s.sliceToExclusive(s.getPosition(readLen));
        return .{
            .context = context,
            .sequence = newSequence,
            .initialLen = readLen,
            .isLast = isLastChunkDataRead,
            .initialSequencePtr = s,
        };
    }

    fn apply(self: *SliceHelper) void
    {
        self.context.common.sequence = &self.sequence;
        self.context.isLastChunkSequenceSlice = self.isLast;
    }

    fn unapply(self: *SliceHelper) void
    {
        const s = self.initialSequencePtr;
        s.* = s.sliceFrom(self.sequence.start());
        self.context.common.sequence = s;

        const chunk = &self.context.state.chunk;
        chunk.bytesRead += @intCast(self.initialLen - self.sequence.len());

        self.context.isLastChunkSequenceSlice = undefined;
    }

    fn assertConsumed(self: *SliceHelper) void
    {
        if (self.sequence.len() == 0)
        {
            return;
        }

        const chunk = &self.context.state.chunk;
        const bytesLeft = self.sequence.len();
        const msg = "Not all bytes consumed for chunk '{}'. Bytes left: {}";
        std.debug.print(msg, .{ chunk.object.type, bytesLeft });
        unreachable;
    }
};

// Segment CRCCalculation begin
pub fn parseChunkItem(context: *Context) !bool
{
    const chunk = &context.state.chunk;

    try context.level().pushInit(ChunkItemNodeInitializer
    {
        .context = context,
    });
    defer context.level().pop();

    const shouldComputeCrc = chunk.action != .Length and chunk.action != .CyclicRedundancyCheck;
    const previousSequence = context.sequence().*;
    defer if (shouldComputeCrc)
    {
        const consumedSequence = previousSequence.sliceToExclusive(context.sequence().start());
        chunk.crcState = common.updateCrc(chunk.crcState, consumedSequence);
    };
    // Segment CRCCalculation end

    switch (chunk.action)
    {
        .Length => 
        {
            const len = utils.readPngU32(context.sequence())
                catch
                {
                    return error.LengthValueTooLarge;
                };

            chunk.action = .ChunkType;

            chunk.object.dataByteLen = len;
            try context.level().completeNodeWithValue(.{ 
                .Number = len,
            });

            return false;
        },
        .ChunkType =>
        {
            if (context.sequence().len() < 4)
            {
                return error.NotEnoughBytes;
            }

            var chunkType: chunks.RawChunkType = undefined;

            const sequence_ = context.sequence();
            const chunkEndPosition = sequence_.getPosition(4);
            const o = sequence_.disect(chunkEndPosition);
            sequence_.* = o.right;

            o.left.copyTo(&chunkType.bytes);

            const convertedChunkType = chunks.getKnownDataChunkType(chunkType);

            // Might have a special data slot for unknown chunk type?
            chunk.object.type = convertedChunkType;
            try context.level().completeNodeWithValue(.{
                .ChunkType = convertedChunkType,
            });

            if (context.state.imageHeader == null
                and convertedChunkType != .ImageHeader)
            {
                return error.IHDRChunkNotFirst;
            }

            if (context.state.isData 
                and convertedChunkType != .ImageEnd
                and convertedChunkType != .ImageData)
            {
                return error.OnlyEndOrDataAllowedAfterIDAT;
            }

            chunk.action = .Data;
            return false;
        },
        .Data =>
        {
            var sliceHelper = SliceHelper.create(context);
            sliceHelper.apply();
            defer sliceHelper.unapply();

            const done = try chunks.parseChunkData(context);
            if (done)
            {
                sliceHelper.assertConsumed();
                chunk.action = .CyclicRedundancyCheck;
                try context.level().completeNode();
            }
            return false;
        },
        // Segment CRCCheck begin
        .CyclicRedundancyCheck =>
        {
            const value = try pipelines.readNetworkUnsigned(context.sequence(), u32);
            const crc = .{ .value = value };
            chunk.object.crc = crc;

            try context.level().completeNodeWithValue(.{
                .U32 = value,
            });

            const computedCrc = ~chunk.crcState;
            if (computedCrc != value)
            {
                return error.CyclicRedundancyCheckMismatch;
            }

            return true;
        },
        // Segment CRCCheck end
    }
}


pub fn createParserState() State
{
    return .{
        .chunk = createChunkParserState(),
    };
}

fn createChunkParserState() common.ChunkState
{
    return .{
        .object = std.mem.zeroes(common.Chunk),
        .dataState = undefined,
    };
}

