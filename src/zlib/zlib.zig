const deflate = @import("deflate.zig");
const helper = @import("helper.zig");
const std = @import("std");
const pipelines = helper.pipelines;

const Header = struct
{
    compressionMethod: CompressionMethodAndFlags,
    flags: Flags,
    dictionaryId: u4,
};

const Action = enum
{
    CompressionMethodAndFlags,
    Flags,
    PresetDictionary,
    CompressedData,
    Adler32Checksum,
    Done,
};

const Adler32State = struct
{
    a: u32 = 1,
    b: u32 = 0,

    pub fn update(self: Adler32State, buffer: []const u8) void
    {
        for (buffer) |byte|
        {
            // first prime less than 2^16
            const modulus = 65521;
            self.a = (self.a + byte) % modulus;
            self.b = (self.b + self.a) % modulus;
        }
    }

    pub fn updateWithSequence(self: Adler32State, sequence: *const pipelines.Sequence) void
    {
        var iter = pipelines.SegmentIterator.create(sequence) orelse return;
        while (true)
        {
            self.update(iter.current());
            if (!iter.advance())
            {
                break;
            }
        }
    }

    pub fn getChecksum(self: Adler32State) u32
    {
        return (self.b << 16) | self.a;
    }
};

pub const State = struct
{
    action: Action = .CompressionMethodAndFlags,
    adler32: Adler32State = .{},

    decompressor: union
    {
        none: void,
        deflate: deflate.State,
    } = .{ .none = {} },

    data: union
    {
        none: void,
        // Used for checks
        cmf: CompressionMethodAndFlags,
        dictionaryId: u32,
    } = .{ .none = {} },
};

const CompressionMethodAndFlags = packed struct
{
    compressionMethod: CompressionMethod,
    compressionInfo: CompressionInfo,
};

const CompressionMethod = enum(u4)
{
    Deflate = 8,
    Reserved = 15,
    _,
};

const CompressionInfo = u4;

const Flags = packed struct
{
    check: u4,
    presetDictionary: bool,
    compressionLevel: CompressionLevel,
};

const CompressionLevel = enum(u3)
{
    Fastest = 0,
    Fast = 1,
    Default = 2,
    SlowMaximumCompression = 3,
};

const PresetDictionary = struct {};

fn checkCheckFlag(cmf: CompressionMethodAndFlags, flags: Flags) bool
{
    const cmfByte: u8 = @bitCast(cmf);
    const flagsByte: u8 = @bitCast(flags);
    const value: u16 = (@as(u16, cmfByte) << 8) | @as(u16, flagsByte);
    const remainder = value % 31;
    return remainder == 0;
}

const Context = struct
{
    common: *const helper.CommonContext,
    state: *State,

    pub fn output(self: *const Context) *helper.OutputBuffer
    {
        return self.common.output;
    }
    pub fn sequence(self: *const Context) *pipelines.Sequence
    {
        return self.common.sequence;
    }
};

pub fn decode(context: *const Context) !bool
{
    const state = context.state;

    if (false)
    {
        const sequenceBefore = context.sequence().*;
        // We don't need to 
        const shouldComputeChecksum = state.action != .Adler32Checksum;
        defer if (shouldComputeChecksum)
        {
            const newSequenceStart = context.sequence().start();
            const readSequence = sequenceBefore.sliceToExclusive(newSequenceStart);
            context.state.adler32.update(&readSequence);
        };
    }

    switch (state.action)
    {
        .CompressionMethodAndFlags =>
        {
            const value = try pipelines.removeFirst(context.sequence());
            const cmf: CompressionMethodAndFlags = @bitCast(value);
            state.data.cmf = cmf;

            switch (cmf.compressionMethod)
            {
                .Deflate =>
                {
                    const logBase2OfWindowSize = cmf.compressionInfo;
                    const windowSize = @as(u16, 1) << logBase2OfWindowSize;
                    context.output().setWindowSize(windowSize);

                    state.decompressor = .{
                        .deflate = .{},
                    };
                    state.action = Action.Flags;
                },
                else => return error.UnsupportedCompressionMethod,
            }
        },
        .Flags =>
        {
            const value = try pipelines.removeFirst(context.sequence());
            const flags: Flags = @bitCast(value);
            const flagValid = checkCheckFlag(state.data.cmf, flags);
            if (!flagValid)
            {
                return error.InvalidFlags;
            }

            if (flags.presetDictionary)
            {
                state.action = .PresetDictionary;
                return error.PresetDictionaryNotSupported;
            }
            else
            {
                state.action = .CompressedData;
            }
        },
        .PresetDictionary =>
        {
            const value = try pipelines.readNetworkUnsigned(context.sequence(), u32);
            state.data.dictionaryId = value;
            state.action = .CompressedData;
        },
        .CompressedData =>
        {
            const decompressor = &state.decompressor.deflate;

            const bufferPositionBefore = context.output().position;
            defer
            {
                const currentPosition = context.output().position;
                const addedBytes = context.output().buffer[bufferPositionBefore .. currentPosition];
                state.adler32.update(addedBytes);
            }

            const deflateContext = deflate.Context
            {
                .common = context.common,
                .state = decompressor,
            };

            const doneWithBlock = try deflate.deflate(&deflateContext);
            if (doneWithBlock and decompressor.isFinal)
            {
                state.action = .Adler32Checksum;
            }
            if (doneWithBlock)
            {
                decompressor.action = deflate.Action.Initial;
            }
        },
        .Adler32Checksum =>
        {
            const checksum = try pipelines.readNetworkUnsigned(context.sequence(), u32);
            state.checksum = checksum;

            const computedChecksum = state.adler32.getChecksum();
            if (checksum != computedChecksum)
            {
                return error.ChecksumMismatch;
            }

            return true;
        },
        .Done => unreachable,
    }
}

pub fn decodeAsMuchAsPossible(context: *const Context) !void
{
    while (true)
    {
        const done = try decode(context);
        if (done)
        {
            return true;
        }
    }
}

fn copyConst(from: type, to: type) type
{
    return @Type(t: {
        var info = @typeInfo(to).Pointer;
        info.is_const = @typeInfo(from).Pointer.is_const;
        break :t info;
    });
}

test
{
    _ = deflate;
}

test "failing tests"
{
    const examplesDirectoryPath = "references/tests/decomp-bad-inputs";
    const cwd = std.fs.cwd();

    var allExamplesDirectory = try cwd.openDir(examplesDirectoryPath, .{
        .iterate = true,
    });
    defer allExamplesDirectory.close();

    var exampleDirectories = allExamplesDirectory.iterate();
    while (try exampleDirectories.next()) |exampleDirectoryEntry|
    {
        std.debug.assert(exampleDirectoryEntry.kind == .directory);

        var exampleDirectory = try allExamplesDirectory.openDir(exampleDirectoryEntry.name, .{
            .iterate = true,
        });
        defer exampleDirectory.close();

        var exampleFiles = exampleDirectory.iterate();
        while (try exampleFiles.next()) |exampleFileEntry|
        {
            if (true)
            {
                if (!std.mem.eql(u8, exampleDirectoryEntry.name, "00"))
                {
                    continue;
                }

                if (!std.mem.eql(u8, exampleFileEntry.name, "id_000000_sig_11_src_000000_op_flip1_pos_10"))
                {
                    continue;
                }
            }

            const exampleFile = try exampleDirectory.openFile(exampleFileEntry.name, .{});
            defer exampleFile.close();
            const reader = exampleFile.reader();

            const testResult = try doTest(reader);
            if (testResult.err) |_| {}
            else
            {
                std.debug.print("Test {s} didn't fail\n", .{ exampleFileEntry.name });
                return;
            }
        }
    }
}

fn doTest(file: anytype)
    !struct
    {
        err: ?anyerror,
        state: State,
        filePosition: usize,
    }
{
    const allocator = std.heap.page_allocator;
    var reader = pipelines.Reader(@TypeOf(file))
    {
        .dataProvider = file,
        .allocator = allocator,
        .preferredBufferSize = 4096 * 4,
    };
    defer reader.deinit();

    var outputBuffer = outputBuffer:
    {
        // Pretty arbitrary, but right now there's just the buffer, straight up.
        // There's no resizing of any sort.
        const bufferSize = 4096 * 8;
        const buffer = try allocator.alloc(u8, bufferSize);

        break :outputBuffer helper.OutputBuffer
        {
            .buffer = buffer,
            .position = 0,
            .windowSize = undefined,
        };
    };
    defer outputBuffer.deinit(allocator);

    var state = State{};
    var resultError: ?anyerror = null;

    outerLoop: while (true)
    {
        const readResult = try reader.read();
        var sequence = readResult.sequence;

        const common = helper.CommonContext
        {
            .sequence = &sequence,
            .output = &outputBuffer,
            .allocator = allocator,
        };

        const context = Context
        {
            .state = &state,
            .common = &common,
        };

        decodeAsMuchAsPossible(&context)
        catch |err|
        {
            const isRecoverableError = err:
            {
                switch (err)
                {
                    error.NotEnoughBytes => break :err true,
                    else =>
                    {
                        std.debug.print("Error: {}\n", .{ err });
                        break :err false;
                    },
                }
            };

            if (!isRecoverableError)
            {
                resultError = err;
                break :outerLoop;
            }
        };

        if (readResult.isEnd)
        {
            const remaining = context.sequence().len();
            if (remaining > 0)
            {
                std.debug.print("Not all input consumed. Remaining length: {}\n", .{remaining});
                resultError = error.NotAllInputConsumed;
                break :outerLoop;
            }

            if (context.state.action != .Done)
            {
                std.debug.print("Ended in a non-terminal state.", .{});
                resultError = error.UnexpectedEndOfInput;
                break :outerLoop;
            }
        }
    }

    for (0 .., outputBuffer.buffer[0 .. outputBuffer.position]) |i, byte|
    {
        if (i % 16 == 0)
        {
            std.debug.print("\n", .{});
        }
        switch (byte)
        {
            ' ' ... '~' =>
            {
                std.debug.print("{c}  ", .{ byte });
            },
            else =>
            {
                std.debug.print("{:02x} ", byte);
            },
        }
    }

    return .{
        .err = resultError,
        .state = state,
        .filePosition = reader.buffer().getBytePosition(),
    };
}
