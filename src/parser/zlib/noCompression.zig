const helper = @import("helper.zig");
const pipelines = helper.pipelines;

const DeflateContext = helper.DeflateContext;

pub fn decompress(context: *DeflateContext, state: *DecompressionState) !void
{
    if (state.bytesLeftToCopy == 0)
    {
        return;
    }

    const sequence = context.sequence();
    var iter = pipelines.SegmentIterator.create(sequence)
        orelse return error.NotEnoughBytes;
    while (true)
    {
        const segment = iter.current();
        const len = segment.len;
        const bytesWillRead = @min(state.bytesLeftToCopy, len);

        const slice = segment[0 .. bytesWillRead];
        context.output().writeBytes(slice)
            catch |err|
            {
                sequence.* = sequence.sliceFrom(iter.currentPosition);
                return err;
            };

        state.bytesLeftToCopy -= bytesWillRead;
        if (state.bytesLeftToCopy == 0)
        {
            const currentPos = iter.currentPosition.add(bytesWillRead);
            sequence.* = sequence.sliceFrom(currentPos);
            break;
        }

        const advanced = iter.advance();
        if (!advanced)
        {
            sequence.* = sequence.sliceFrom(iter.currentPosition);
            return error.NotEnoughBytes;
        }
    }
}

pub const InitStateAction = enum
{
    Len,
    NLen,
};

pub const State = union
{
    init: InitState,
    decompression: DecompressionState,
};

pub const InitState = struct
{
    action: InitStateAction = .Len,
    len: u16,
    nlen: u16,
};

pub const DecompressionState = struct
{
    bytesLeftToCopy: u16,
};

pub fn initState(context: *DeflateContext, state: *InitState) !bool
{
    try context.level().pushNode(.{
        .NoCompression = state.action,
    });
    defer context.level().pop();

    switch (state.action)
    {
        .Len =>
        {
            const len = try pipelines.readNetworkUnsigned(context.sequence(), u16);
            state.len = len;
            try context.level().completeNodeWithValue(.{
                .Number = len,
            });
            state.action = .NLen;
            return false;
        },
        .NLen =>
        {
            const nlen = try pipelines.readNetworkUnsigned(context.sequence(), u16);
            state.nlen = nlen;

            try context.level().completeNodeWithValue(.{
                .Number = nlen,
            });

            if (nlen != ~state.len)
            {
                return error.NLenNotOnesComplement;
            }
            return true;
        },
    }
}
