pub const deflate = @import("deflate.zig");
const helper = @import("helper.zig");
const parser = helper.parser;
const std = @import("std");
const pipelines = parser.pipelines;

pub const OutputBuffer = deflate.OutputBuffer;
const LevelContext = parser.level.LevelContext;

const Header = struct
{
    compressionMethod: CompressionMethodAndFlags,
    flags: Flags,
    dictionaryId: u4,
};

pub const Action = enum
{
    CompressionMethodAndFlags,
    Flags,
    PresetDictionary,
    CompressedData,
    Adler32Checksum,
};

const Adler32State = struct
{
    a: u32 = 1,
    b: u32 = 0,

    pub fn update(self: *Adler32State, buffer: []const u8) void
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
        var iter = sequence.iterate() orelse return;
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

test "Adler32"
{
    const str = "1234567890qwertyuiop";
    var adler: Adler32State = .{};
    adler.update(str);
    try std.testing.expectEqual(0x38090677, adler.getChecksum());
}

pub const State = struct
{
    action: Action = .CompressionMethodAndFlags,
    windowSize: usize = 0,
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

pub const CompressionMethodAndFlags = packed struct
{
    compressionMethod: CompressionMethod,
    compressionInfo: CompressionInfo,
};

pub const CompressionMethod = enum(u4)
{
    Deflate = 8,
    Reserved = 15,
    _,
};

pub const CompressionInfo = u4;

pub const Flags = packed struct
{
    check: u5,
    presetDictionary: bool,
    compressionLevel: CompressionLevel,
};

const CompressionLevel = enum(u2)
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

pub const CommonContext = helper.CommonContext;

pub const Context = struct
{
    common: *CommonContext,
    state: *State,

    pub fn level(self: *Context) *LevelContext(Context)
    {
        return .{
            .data = self.common.levelData(),
            .context = self,
        };
    }
    pub fn output(self: *Context) *helper.OutputBuffer
    {
        return self.common.output;
    }
    pub fn sequence(self: *Context) *pipelines.Sequence
    {
        return self.common.sequence();
    }
    pub fn getStartBytePosition(self: *Context) parser.ast.Position
    {
        return .{
            .byte = self.sequence().getStartBytePosition(),
            .bit = 0,
        };
    }
    pub fn nodeContext(self: *Context) *parser.NodeContext
    {
        return self.common.nodeContext();
    }
};

pub fn decode(context: *Context) !bool
{
    const state = context.state;

    try context.level().pushNode(.{
        .Zlib = state.action,
    });
    defer context.level().pop();

    switch (state.action)
    {
        .CompressionMethodAndFlags =>
        {
            const value = try pipelines.removeFirst(context.sequence());
            const cmf: CompressionMethodAndFlags = @bitCast(value);
            state.data = .{ .cmf = cmf };
            try context.level().completeNodeWithValue(.{
                .CompressionMethodAndFlags = cmf,
            });

            switch (cmf.compressionMethod)
            {
                .Deflate =>
                {
                    const logBase2OfWindowSize = cmf.compressionInfo;
                    const windowSize = @as(usize, 1) << (logBase2OfWindowSize + 8);
                    context.state.windowSize = windowSize;

                    state.decompressor = .{
                        .deflate = .{},
                    };
                    state.action = .Flags;
                },
                else => return error.UnsupportedCompressionMethod,
            }
        },
        .Flags =>
        {
            const value = try pipelines.removeFirst(context.sequence());
            const flags: Flags = @bitCast(value);
            try context.level().completeNodeWithValue(.{
                .ZlibFlags = flags,
            });

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
            state.data = .{ .dictionaryId = value };
            try context.level().completeNodeWithValue(.{
                .Number = value,
            });
            state.action = .CompressedData;
        },
        .CompressedData =>
        {
            const decompressor = &state.decompressor.deflate;

            const bufferPositionBefore = context.output().position();
            defer
            {
                const currentPosition = context.output().position();
                const addedBytes = context.output().buffer()[bufferPositionBefore .. currentPosition];
                state.adler32.update(addedBytes);
            }

            var deflateContext = deflate.Context
            {
                .common = context.common,
                .state = decompressor,
            };

            const doneWithBlock = try deflate.deflate(&deflateContext);
            if (doneWithBlock and decompressor.isFinal)
            {
                state.action = .Adler32Checksum;
                deflate.skipToWholeByte(&deflateContext);
            }
            if (doneWithBlock)
            {
                try context.level().completeNode();
                decompressor.action.* = deflate.Action.Initial;
            }
        },
        .Adler32Checksum =>
        {
            const checksum = try pipelines.readNetworkUnsigned(context.sequence(), u32);
            try context.level().completeNodeWithValue(.{
                .U32 = checksum,
            });

            const computedChecksum = state.adler32.getChecksum();
            std.debug.print("Checksum expected: {x:0>16}, Computed: {x:0>16}\n", .{ checksum, computedChecksum });

            if (checksum != computedChecksum)
            {
                return error.ChecksumMismatch;
            }

            return true;
        },
    }
    return false;
}

pub fn decodeAsMuchAsPossible(context: *Context) !void
{
    while (true)
    {
        const done = try decode(context);
        if (done)
        {
            return;
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
    _ = helper;
}

test "failing tests"
{
    // The examples are gzip, not zlib.
    // We don't parse gzip.
    if (true)
    {
        return;
    }

    const examplesDirectoryPath = "references/uzlib/tests/decomp-bad-inputs";

    const cwd = std.fs.cwd();

    const allocator = std.heap.page_allocator;

    if (false)
    {
        const cwdPath = try cwd.realpathAlloc(allocator, "");
        std.debug.print("cwd: {s}\n", .{ cwdPath });
        allocator.free(cwdPath);
    }

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
            if (false)
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

            const testResult = try doTest(reader, allocator);
            if (testResult.err) |_| {}
            else
            {
                std.debug.print("Test {s} didn't fail\n", .{ exampleFileEntry.name });
                return;
            }
        }
    }
}

fn doTest(file: anytype, allocator: std.mem.Allocator)
    !struct
    {
        err: ?anyerror,
        state: State,
        filePosition: usize,
    }
{
    var reader = pipelines.Reader(@TypeOf(file))
    {
        .dataProvider = file,
        .allocator = allocator,
        .preferredBufferSize = 4096 * 4,
    };
    defer reader.deinit();

    var outputBuffer = outputBuffer:
    {
        break :outputBuffer helper.OutputBuffer
        {
            .buffer = .{
                .allocator = allocator,
            },
            .position = 0,
            .windowSize = undefined,
        };
    };
    defer outputBuffer.deinit(allocator);

    var state = State{};
    var resultError: ?anyerror = null;
    var sequence: pipelines.Sequence = undefined;
    var settings: helper.Settings = .{};

    outerLoop: while (true)
    {
        const readResult = try reader.read();
        sequence = readResult.sequence;

        const common = CommonContext
        {
            .sequence = &sequence,
            .output = &outputBuffer,
            .allocator = allocator,
            .settings = &settings,
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
                std.debug.print("Ended in a non-terminal state.\n", .{});
                resultError = error.UnexpectedEndOfInput;
                break :outerLoop;
            }
        }
    }

    for (0 .., outputBuffer.buffer()) |i, byte|
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
                std.debug.print("{x:02} ", .{ byte });
            },
        }
    }

    return .{
        .err = resultError,
        .state = state,
        .filePosition = sequence.getStartBytePosition(),
    };
}
