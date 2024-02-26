const std = @import("std");

pub const SequencePosition = struct {
    segment: u32,
    offset: u32,

    pub fn add(self: SequencePosition, offset: u32) SequencePosition
    {
        return .{
            .segment = self.segment,
            .offset = self.offset + offset,
        };
    }

    // Is this fine? 
    // To actually be able to compare, it needs to know the segment lengths too.
    // Only call this if you're sure the positions are normalized to the buffer.
    pub fn compare(self: SequencePosition, other: SequencePosition) i32
    {
        const local = struct 
        {
            fn compareUint(a: u32, b: u32) i32
            {
                if (a < b)
                {
                    return -1;
                }
                if (a > b)
                {
                    return 1;
                }
                return 0;
            }
        };

        {
            const r = local.compareUint(self.segment, other.segment);
            if (r != 0)
            {
                return r;
            }
        }
        {
            const r = local.compareUint(self.offset, other.offset);
            if (r != 0)
            {
                return r;
            }
        }
        return 0;
    }

    pub const Start = SequencePosition { 
        .offset = 0,
        .segment = 0,
    };
    pub const End = SequencePosition { 
        .offset = std.math.maxInt(u32), 
        .segment = std.math.maxInt(u32),
    };
};

fn bytesEqual(a: anytype, b: @TypeOf(a)) bool
{
    for (std.mem.asBytes(&a), std.mem.asBytes(&b)) |a_elem, b_elem| 
    {
        if (a_elem != b_elem) 
        {
            return false;
        }
    }
    return true;
}

pub const Segment = struct 
{
    array: []const u8,
    len: u32,
    bytePosition: usize,

    pub fn getSlice(self: *const Segment) []const u8
    {
        return self.array[0 .. self.len];
    }

    pub fn isLastSegment(self: *const Segment) bool
    {
        return self.len < self.array.len;
    }

    pub fn getBytePosition(self: *const Segment) usize
    {
        return self.bytePosition;
    }
};

pub const Buffer = struct 
{
    segments: std.ArrayListUnmanaged(Segment),
    firstSegmentOffset: u32,
    totalBytes: usize,

    fn getFirstSegmentOffset(self: *const Buffer) u32
    {
        return self.firstSegmentOffset;
    }

    pub fn getSegment(self: *const Buffer, segmentIndex: u32) []const u8
    {
        const segments_ = self.segments.items;
        const actualIndex = getSegmentIndex(self, segmentIndex);
        return segments_[actualIndex].getSlice();
    }

    fn getSegmentIndex(self: *const Buffer, segmentIndex: u32) usize
    {
        const f_ = self.getFirstSegmentOffset();
        std.debug.assert(segmentIndex >= f_);
        const result = @as(usize, segmentIndex) - f_;
        return result;
    }

    pub fn getBytePosition(self: *const Buffer, position: SequencePosition) usize
    {
        const segments_ = self.segments.items;
        if (segments_.len == 0)
        {
            return self.totalBytes;
        }

        const actualIndex = self.getSegmentIndex(position.segment);
        return segments_[actualIndex].getBytePosition() + position.offset;
    }

    pub fn allByteCount(self: *const Buffer) usize
    {
        return self.totalBytes;
    }

    pub fn appendSegment(
        self: *Buffer,
        segment: Segment,
        allocator: std.mem.Allocator) !void
    {
        try self.segments.append(allocator, segment);
        self.totalBytes += segment.len;
    }
};

pub const SequenceRange = struct {
    start: SequencePosition,

    // exclusive.
    end: SequencePosition,

    pub fn slice(
        self: SequenceRange,
        newStart: ?SequencePosition,
        newEnd: ?SequencePosition) SequenceRange 
    {
        // This one might actually be wrong...
        if (newStart) |s|
        {
            std.debug.assert(s.segment >= self.start.segment
                or s.segment == SequencePosition.Start.segment);
            std.debug.assert(s.offset >= self.start.offset
                or s.offset == SequencePosition.Start.offset);
        }
        if (newEnd) |e|
        {
            std.debug.assert(e.segment <= self.end.segment 
                or e.segment == SequencePosition.End.segment);
            std.debug.assert(e.offset <= self.end.offset 
                or e.offset == SequencePosition.End.offset);
        }

        const start_ = newStart orelse self.start;
        const end_ = newEnd orelse self.end;

        // Can't really do this...
        // std.debug.assert(start_.segment <= end_.segment);

        if (start_.segment == end_.segment)
        {
            std.debug.assert(start_.offset <= end_.offset);
        }

        return SequenceRange
        {
            .start = start_,
            .end = end_,
        };
    }
};

pub const Sequence = struct 
{
    buffer: *const Buffer,
    range: SequenceRange,

    const Self = @This();

    pub fn createEmpty(buffer: *const Buffer) Sequence
    {
        const pos = SequencePosition {
            .offset = 0,
            .segment = @intCast(buffer.getFirstSegmentOffset()),
        };
        return .{
            .buffer = buffer,
            .range = .{
                .start = pos,
                .end = pos,
            },
        };
    }

    pub fn create(buffer: *const Buffer) Sequence
    {
        const segments_ = buffer.segments.items;
        if (segments_.len == 0)
        {
            return Self.createEmpty(buffer);
        }

        const start_ = SequencePosition
        {
            .offset = 0,
            .segment = buffer.getFirstSegmentOffset(),
        };
        const lastSegment_ = segments_[segments_.len - 1];
        const end_ = SequencePosition
        {
            .offset = lastSegment_.len,
            .segment = @intCast(buffer.getFirstSegmentOffset() + segments_.len - 1),
        };
        return .{
            .buffer = buffer,
            .range = .{
                .start = start_,
                .end = end_,
            },
        };
    }

    pub fn start(self: *const Self) SequencePosition 
    {
        return self.range.start;
    }

    pub fn end(self: *const Self) SequencePosition 
    {
        return self.range.end;
    }

    pub fn len(self: *const Self) usize
    {
        const start_ = self.start();
        const end_ = self.end();
        const startAbsolute = self.buffer.getBytePosition(start_);
        const endAbsolute = self.buffer.getBytePosition(end_);
        return endAbsolute - startAbsolute;
    }

    pub fn getStartOffset(self: *const Self) usize
    {
        return getOffset(self, self.start());
    }

    pub fn getOffset(self: *const Self, position: SequencePosition) usize
    {
        return self.buffer.getBytePosition(position);
    }

    pub fn getPosition(self: *const Self, offset: usize) SequencePosition
    {
        std.debug.assert(offset <= self.len());

        if (offset == 0)
        {
            return self.start();
        }

        const startOffset = self.buffer.getBytePosition(self.start());
        const targetBytePosition = startOffset + offset;

        const segments_ = self.buffer.segments.items;
        // let's just linearly search for now.
        for (segments_, 0 ..) |*s, i|
        {
            if (s.getBytePosition() + s.len >= targetBytePosition)
            {
                return .{
                    .segment = @intCast(i),
                    .offset = @intCast(targetBytePosition - s.bytePosition),
                };
            }
        }

        unreachable;
    }

    pub fn isEmpty(self: *const Self) bool
    {
        return self.len() == 0;
    }

    pub fn getWholeSegmentCount(self: *const Self) u32
    {
        const start_ = self.start();
        const end_ = self.end();
        var result = end_.segment - start_.segment;
        if (end_.offset == self.buffer.getSegment(end_.segment).len)
        {
            result += 1;
        }
        return result;
    }

    pub fn sliceFrom(self: *const Self, newStart: SequencePosition) Sequence
    {
        return self.slice(.{
            .start = newStart,
            .end = self.end(),
        });
    }

    pub fn sliceToExclusive(self: *const Self, newEnd: SequencePosition) Sequence
    {
        return self.slice(.{
            .start = self.start(),
            .end = newEnd,
        });
    }

    // Creates two slices:
    // One up to the middle position, exclusive.
    // Second from the middle position, inclusive.
    pub fn disect(self: *const Self, middle: SequencePosition) 
        struct
        { 
            left: Sequence,
            right: Sequence,
        }
    {
        const left = self.sliceToExclusive(middle);
        const right = self.sliceFrom(middle);
        return .{
            .left = left,
            .right = right
        };
    }

    // // Removes a sequence from the start until the given position and returns it.
    // pub fn cutOffUntil(self: *Self, until: SequencePosition) Sequence
    // {
    //     const result = self.disect(until);
    //     self.* = result.rigth;
    //     return result.left;
    // }

    pub fn slice(
        self: *const Self,
        range: SequenceRange) Sequence
    {
        var range_ = range;

        const local = struct
        {
            fn collapseEnds(s: *const Self, pos: *SequencePosition) void
            {
                if (bytesEqual(pos.*, SequencePosition.End))
                {
                    pos.* = s.end();
                }
                else if (bytesEqual(pos.*, SequencePosition.Start))
                {
                    pos.* = s.start();
                }
            }
        };
        local.collapseEnds(self, &range_.start);
        local.collapseEnds(self, &range_.end);

        const willMoveEnd = range_.end.offset == 0 and range.end.segment > 0;

        // Collapse the end position of the range into the previous segment if the offset is 0.
        if (willMoveEnd)
        {
            const endSegment = self.buffer.getSegment(range_.end.segment - 1);
            range_.end.segment -= 1;
            range_.end.offset = @intCast(endSegment.len);
        }

        // If the start happened to go past the end, 
        // it's either an error, which we check with an assert,
        // or it happens to be the same position as the end after we move it into the previous segment.
        // TODO: Maybe allow empty segments? The all of these just have to be while loops.
        if (range_.start.segment > range_.end.segment)
        {
            const diff = range_.start.segment - range_.end.segment;
            std.debug.assert(diff == 1);

            std.debug.assert(range_.start.offset == 0);

            // The position has to overlap exactly with the end position.
            const endSegment = self.buffer.getSegment(range_.end.segment);
            std.debug.assert(range_.end.offset == endSegment.len);

            range_.start.segment -= 1;
            // Empty segment that starts and ends at the end of the single segment.
            range_.start.offset = @intCast(endSegment.len);
        }

        // At this point we know the segments have been validated.
        // Throwing this in just to be sure.
        std.debug.assert(range_.start.segment <= range_.end.segment);

        // Need to normalize the slice.

        // If they ended up in the same segment, we keep them as is.

        // Else, they are at least 1 segment apart.
        // If they are exactly 1 segment apart, need need to be careful to make sure
        // the start doesn't go past the end.
        if (range_.end.segment != range_.start.segment)
        {
            const startSegment = self.buffer.getSegment(range_.start.segment);
            const startWillBeMoved = range_.start.offset == startSegment.len;
            const areInSameSegment = range_.end.segment - range_.start.segment == 1;
            const dontMoveStart = areInSameSegment and willMoveEnd;

            if (startWillBeMoved and !dontMoveStart)
            {
                range_.start.segment += 1;
                range_.start.offset = 0;
            }
        }

        std.debug.assert(range_.end.segment >= range_.start.segment);

        return .{
            .buffer = self.buffer,
            .range = range_,
        };
    }

    pub fn copyTo(self: *const Self, buffer: []u8) void
    {
        var buffer_ = buffer;
        std.debug.assert(self.len() == buffer_.len);

        var iter = SegmentIterator.create(self) 
        // We know the buffer is empty in this case.
        orelse {
            std.debug.assert(buffer_.len == 0);
            return;
        };

        while (true)
        {
            const segment = iter.current();
            const bytesToCopy = @min(segment.len, buffer_.len);
            @memcpy(buffer_[0 .. bytesToCopy], segment[0 .. bytesToCopy]);

            buffer_ = buffer_[bytesToCopy ..];
            if (buffer_.len == 0)
            {
                return;
            }

            if (!iter.advance())
            {
                unreachable;
            }
        }
    }

    pub fn getFirstSegment(self: *const Self) []const u8
    {
        const start_ = self.start();
        const wholeSegment = self.buffer.getSegment(start_.segment);
        return wholeSegment[start_.offset ..];
    }

    pub fn peekFirstByte(self: *const Self) ?u8
    {
        if (self.isEmpty())
        {
            return null;
        }
        const firstSegment = self.getFirstSegment();
        return firstSegment[0];
    }

    pub fn debugPrint(self: *const Self) void
    {
        const allocator = std.heap.page_allocator;
        const mem = allocator.alloc(u8, self.len()) catch unreachable;
        defer allocator.free(mem);
        self.copyTo(mem);
        std.debug.print("Sequence: {s}\n", .{mem});
    }
};

pub const SegmentIterator = struct 
{
    sequence: *const Sequence,
    currentPosition: SequencePosition,

    pub fn create(sequence: *const Sequence) ?SegmentIterator
    {
        if (sequence.isEmpty())
        {
            return null;
        }

        return .{
            .sequence = sequence,
            .currentPosition = sequence.start(),
        };
    }

    pub fn current(self: *SegmentIterator) []const u8
    {
        const start_ = &self.currentPosition;
        const end_ = self.sequence.end();
        const segment = self.sequence.buffer.getSegment(start_.segment);
        if (start_.segment == end_.segment)
        {
            return segment[start_.offset .. end_.offset];
        }
        else
        {
            return segment[start_.offset .. segment.len];
        }
    }

    pub fn advance(self: *SegmentIterator) bool
    {
        // I try to keep the ends in the same segment 
        // such that there are no empty segments.
        // So this should be correct.
        const nextSegment = self.currentPosition.segment + 1;
        const movedPastEnd = nextSegment <= self.sequence.end().segment;
        if (movedPastEnd)
        {
            self.currentPosition = SequencePosition.End;
            return false;
        }
        else
        {
            self.currentPosition.segment = nextSegment;
            self.currentPosition.offset = 0;
            return true;
        }
    }

    pub fn getCurrentPosition(self: *SegmentIterator) SequencePosition
    {
        return self.currentPosition;
    }
};

pub const ReaderResult = struct 
{
    isEnd: bool,
    sequence: Sequence,
};

pub const AdvanceRange = struct {
    consumed: ?SequencePosition = null,
    examined: ?SequencePosition = null,
};

const EOFState = enum {
    FirstRead,
    NotReached,
    Reached,
    AlreadySignaled,
};

pub fn Reader(comptime ReaderType: type) type 
{
    return struct
    {
        const Self = @This();

        preferredBufferSize: usize,
        allocator: std.mem.Allocator,
        dataProvider: ReaderType,

        _buffer: Buffer = std.mem.zeroes(Buffer),
        _consumedUntilPosition: SequencePosition = SequencePosition.Start,
        _eofState: EOFState = .FirstRead,

        pub fn deinit(self: *Self) void
        {
            for (self._buffer.segments.items) |*s|
            {
                self.allocator.free(s.array);
            }
        }

        fn readOneMoreSegment(self: *Self) !Segment
        {
            std.debug.assert(
                self._eofState == .NotReached
                or self._eofState == .FirstRead);

            const newBuffer = try self.allocator.alloc(u8, self.preferredBufferSize);
            errdefer self.allocator.free(newBuffer);

            // TODO: When decoupled from the writer, this should just pause the thread.
            const readCount = try self.dataProvider.read(newBuffer);

            const s = Segment {
                .array = newBuffer,
                .len = @intCast(readCount),
                .bytePosition = self._buffer.allByteCount(),
            };
            if (s.isLastSegment())
            {
                self._eofState = .Reached;
            }
            return s;
        }

        fn currentSequence(self: *Self) Sequence
        {
            const buffer_ = self.buffer();
            const segments_ = buffer_.segments.items;
            if (segments_.len == 0)
            {
                return Sequence.createEmpty(buffer_);
            }

            const lastSegment_ = &segments_[segments_.len - 1];
            return .{
                .buffer = buffer_,
                .range = .{
                    .start = self._consumedUntilPosition,
                    .end = .{ 
                        .segment = @intCast(segments_.len - 1 + buffer_.getFirstSegmentOffset()),
                        .offset = lastSegment_.len,
                    },
                },
            };
        }

        pub fn buffer(self: *Self) *Buffer
        {
            return &self._buffer;
        }

        pub fn advance(
            self: *Self,
            consumedPosition: ?SequencePosition) !void
        {
            const buffer_ = self.buffer();
            const sequence_ = self.currentSequence();
            const newRange_ = sequence_.range.slice(consumedPosition, null);
            const newSequence_ = sequence_.slice(newRange_);

            // Removed segments = from current start until the new start segment.
            {
                const removedSequence = sequence_.slice(.{
                    .start = sequence_.start(),
                    .end = newSequence_.start(),
                });

                const segments = &buffer_.segments.items;
                const removedSegmentsCount = removedSequence.getWholeSegmentCount();

                for (0 .. removedSegmentsCount) |i|
                {
                    self.allocator.free(segments.*[i].array);
                }
                for (removedSegmentsCount .. segments.len) |i|
                {
                    segments.*[i - removedSegmentsCount] = segments.*[i];
                }
                segments.len -= removedSegmentsCount;
            }

            if (self._eofState == .NotReached)
            {
                const newSegment = try self.readOneMoreSegment();
                errdefer self.allocator.free(newSegment.array);

                // You should only call advance once you've scanned all of the input.
                // Or you know you need more.
                try buffer_.appendSegment(newSegment, self.allocator);
            }

            self._consumedUntilPosition = newSequence_.start();
        }

        pub fn read(self: *Self) !ReaderResult
        {
            if (self._eofState == .AlreadySignaled)
            {
                return error.ReadAfterEnd;
            }
            
            const buffer_ = self.buffer();

            if (self._eofState == .FirstRead)
            {
                const newSegment = try self.readOneMoreSegment();
                errdefer self.allocator.free(newSegment.array);

                try buffer_.appendSegment(newSegment, self.allocator);
            }

            const isEnd = self._eofState == .Reached;
            if (isEnd)
            {
                self._eofState = .AlreadySignaled;
            }

            return .{
                .isEnd = isEnd,
                .sequence = self.currentSequence(),
            };
        }
    };
}

const TestDataProvider = struct
{
    data: []const u8,

    pub fn read(self: *TestDataProvider, buffer: []u8) !usize
    {
        const length = @min(buffer.len, self.data.len);
        @memcpy(buffer[0 .. length], self.data[0 .. length]);
        self.data = self.data[length .. self.data.len];
        return length;
    }
};

fn createTestBufferFromData(
    data: []const []const u8,
    allocator: std.mem.Allocator) !Buffer
{
    var segments = std.ArrayListUnmanaged(Segment){};
    try segments.ensureTotalCapacity(allocator, data.len);
    segments.items.len = data.len;

    var length: usize = 0;
    for (data, segments.items) |data_, *s|
    {
        s.* = .{
            .array = data_,
            .len = @intCast(data_.len),
            .bytePosition = length,
        };
        length += data_.len;
    }

    return .{
        .segments = segments,
        .firstSegmentOffset = 0,
        .totalBytes = length,
    };
}

const t = std.testing;

test "isEmpty"
{
    const allocator = std.heap.page_allocator;

    var buffer = try createTestBufferFromData(&.{"123", "456"}, allocator);
    defer buffer.segments.deinit(allocator);

    const wholeSequence = Sequence.create(&buffer);

    {
        const firstSegment = wholeSequence.sliceToExclusive(
            wholeSequence.getPosition(3));
        var iter = SegmentIterator.create(&firstSegment).?;
        try t.expectEqualStrings("123", iter.current());
        try t.expect(!iter.advance());
    }
}

test "copyTo"
{
    const allocator = std.heap.page_allocator;

    var buffer = try createTestBufferFromData(&.{"123", "456"}, allocator);
    defer buffer.segments.deinit(allocator);

    const wholeSequence = Sequence.create(&buffer);

    {
        const sequence = wholeSequence.slice(.{
            .start = wholeSequence.getPosition(1),
            .end = wholeSequence.getPosition(5),
        });

        var localBuffer: [4]u8 = undefined; 
        sequence.copyTo(&localBuffer);

        try t.expectEqualStrings("2345", &localBuffer);
    }
    {
        const sequence = wholeSequence.sliceToExclusive(
            wholeSequence.getPosition(3));
        var localBuffer: [3]u8 = undefined;
        sequence.copyTo(&localBuffer);

        try t.expectEqualStrings("123", &localBuffer);
    }
    {
        const sequence = Sequence.createEmpty(&buffer);
        var localBuffer: [0]u8 = undefined;
        sequence.copyTo(&localBuffer);
        try t.expectEqualStrings("", &localBuffer);
    }
}

test "iterator test"
{
    const allocator = std.heap.page_allocator;
    var reader = Reader(TestDataProvider) 
    {
        .allocator = allocator,
        .dataProvider = .{ .data = "0123456789" },
        .preferredBufferSize = 4,
    };
    {
        const iter = SegmentIterator.create(&reader.currentSequence());
        try t.expect(iter == null);
    }
    {
        const readResult = try reader.read();
        var iter = SegmentIterator.create(&readResult.sequence).?;
        try t.expectEqualStrings("0123", iter.current());
        try t.expect(!iter.advance());
    }
    try reader.advance(null);
    {
        const readResult = try reader.read();
        {
            var iter = SegmentIterator.create(&readResult.sequence).?;
            try t.expectEqualStrings("0123", iter.current());
            try t.expect(iter.advance());
            try t.expectEqualStrings("4567", iter.current());
            try t.expect(!iter.advance());
        }
        {
            var sequence = readResult.sequence;
            sequence = sequence.sliceFrom(sequence.getPosition(2));

            var iter = SegmentIterator.create(&sequence).?;
            try t.expectEqualStrings("23", iter.current());
            try t.expect(iter.advance());
            try t.expectEqualStrings("4567", iter.current());
            try t.expect(!iter.advance());
        }
        {
            var sequence = readResult.sequence;
            sequence = sequence.slice(.{
                .start = sequence.getPosition(2),
                .end = sequence.getPosition(6),
            });

            var iter = SegmentIterator.create(&sequence).?;
            try t.expectEqualStrings("23", iter.current());
            try t.expect(iter.advance());
            try t.expectEqualStrings("45", iter.current());
            try t.expect(!iter.advance());
        }
        {
            var sequence = readResult.sequence;
            sequence = sequence.slice(.{
                .start = sequence.getPosition(2),
                .end = sequence.getPosition(3),
            });

            var iter = SegmentIterator.create(&sequence).?;
            try t.expectEqualStrings("2", iter.current());
            try t.expect(!iter.advance());
        }
    }
}

// only compile this code for tests
const TestHelper = struct
{
    const Self = @This();
    reader: Reader(TestDataProvider),

    pub fn check(
        self: *const Self,
        sequence: Sequence,
        expected: []const u8) !void
    {
        var allocator = self.reader.allocator;
        const buffer = try allocator.alloc(u8, sequence.len());
        defer allocator.free(buffer);
        sequence.copyTo(buffer);

        try t.expectEqualStrings(expected, buffer);
    }
};

fn basicTestSetup() TestHelper
{
    const allocator = std.heap.page_allocator;
    const reader = Reader(TestDataProvider) 
    {
        .allocator = allocator,
        .dataProvider = .{ .data = "0123456789" },
        .preferredBufferSize = 4,
    };

    return .{ 
        .reader = reader,
    };
}
    
test "basic integration tests" {
    var setup = basicTestSetup();

    {
        const readResult = try setup.reader.read();
        try t.expect(!readResult.isEnd);

        const sequence = readResult.sequence;
        try t.expectEqualDeep(SequenceRange{
            .start = .{
                .segment = 0,
                .offset = 0,
            },
            .end = .{
                .segment = 0,
                .offset = 4,
            },
        }, sequence.range);
        try t.expectEqual(@as(usize, 4), sequence.len());
        try t.expectEqual(@as(usize, 1), sequence.buffer.segments.items.len);

        try setup.check(sequence, "0123");
        
        // None consumed.
        try setup.reader.advance(null);
    }
    {
        const readResult = try setup.reader.read();
        try t.expect(!readResult.isEnd);

        const sequence = readResult.sequence;
        try t.expectEqualDeep(SequenceRange{
            .start = .{
                .segment = 0,
                .offset = 0,
            },
            .end = .{
                .segment = 1,
                .offset = 4,
            },
        }, sequence.range);
        try t.expectEqual(@as(usize, 8), sequence.len());
        try t.expectEqual(@as(usize, 2), sequence.buffer.segments.items.len);

        const secondBufferStartPosition = sequence.getPosition(4);
        try setup.check(sequence.slice(.{
            .start = SequencePosition.Start,
            .end = secondBufferStartPosition,
        }), "0123");

        try setup.check(sequence.slice(.{
            .start = secondBufferStartPosition,
            .end = SequencePosition.End,
        }), "4567");

        try setup.check(sequence, "01234567");

        // Let's remove the first two characters.
        const consumedPosition = sequence.getPosition(2);
        try setup.check(sequence.slice(.{
            .start = consumedPosition,
            .end = SequencePosition.End,
        }), "234567");

        try setup.reader.advance(consumedPosition);
    }
    {
        const readResult = try setup.reader.read();
        try t.expect(readResult.isEnd);

        const sequence = readResult.sequence;
        try setup.check(sequence, "23456789");
        try t.expectEqualDeep(SequenceRange{
            .start = .{
                .segment = 0,
                .offset = 2,
            },
            .end = .{
                .segment = 2,
                .offset = 2,
            },
        }, sequence.range);
        try t.expectEqual(@as(usize, 8), sequence.len());
        try setup.check(sequence, "23456789");

        try setup.reader.advance(SequencePosition.End);
    }

    {
        if (setup.reader.read()) |_|
        {
            try t.expect(false);
        }
        else |err|
        {
            try t.expect(error.ReadAfterEnd == err);
        }
    }
}

pub const RemoveResult = error{NotEnoughBytes,NoMatch}!void;

pub fn removeFront(self: *Sequence, string: []const u8) RemoveResult
{
    var string_ = string;
    if (string_.len == 0)
    {
        return;
    }

    var iter = SegmentIterator.create(self).?;
    while (true)
    {
        const segment = iter.current();
        const bytesToCheck: u32 = @intCast(@min(segment.len, string_.len));
        for (0 .. bytesToCheck) |i|
        {
            const a = segment[i];
            const b = string_[i];
            if (a != b)
            {
                const newStart = iter.getCurrentPosition().add(@intCast(i));
                self.* = self.sliceFrom(newStart);
                return error.NoMatch;
            }
        }
        string_ = string_[bytesToCheck .. string_.len];
        if (string_.len == 0)
        {
            const newStart = iter.getCurrentPosition().add(bytesToCheck);
            self.* = self.sliceFrom(newStart);
            return;
        }

        if (!iter.advance())
        {
            self.* = self.sliceFrom(self.end());
            return error.NotEnoughBytes;
        }
    }
}

pub fn removeFirst(sequence: *Sequence) error{NotEnoughBytes}!u8
{
    if (sequence.isEmpty())
    {
        return error.NotEnoughBytes;
    }
    const segment = sequence.getFirstSegment();
    const value = segment[0];
    sequence.* = sequence.sliceFrom(sequence.getPosition(1));
    return value;
}

test "removeFirst works"
{
    var setup = basicTestSetup();

    var r = try setup.reader.read();
    {
        const ch = try removeFirst(&r.sequence);
        try t.expectEqual(ch, '0');
        try t.expectEqual(r.sequence.getStartOffset(), 1);
    }
    {
        const ch = try removeFirst(&r.sequence);
        try t.expectEqual(ch, '1');
        try t.expectEqual(r.sequence.getStartOffset(), 2);
    }
}

pub fn isLittleEndian() bool
{
    const one: [4]u8 = @bitCast(@as(u32, 1));
    return one[0] == 1;
}

pub fn readNetworkU31(self: *Sequence) error{NotEnoughBytes,NumberTooLarge}!u31
{
    if (self.len() < 4)
    {
        return error.NotEnoughBytes;
    }

    const firstByte = self.getFirstSegment()[0];
    if (firstByte & 0x80 != 0)
    {
        return error.NumberTooLarge;
    }

    return @intCast(readNetworkUnsigned_impl(self));
}

// Reverses the byte order if the host is little endian.
pub fn readNetworkUnsigned(self: *Sequence, comptime resultType: type) error{NotEnoughBytes}!resultType
{
    switch (resultType)
    {
        u8 => return try removeFirst(self),
        u16, u32, u64 => {},
        else => unreachable,
    }

    const size = @sizeOf(resultType);
    if (self.len() < size)
    {
        return error.NotEnoughBytes;
    }

    const bytes = readNetworkUnsigned_impl(self, size);
    const result: resultType = @bitCast(bytes);
    return result;
}

fn readNetworkUnsigned_impl(sequence: *Sequence, comptime size: u8) [size]u8
{
    const reverseBytes = isLittleEndian();
    var resultBytes: [size]u8 = undefined;
    var bytesLeftToWrite: u3 = size;

    var iter = SegmentIterator.create(sequence).?;
    while (true)
    {
        const segment = iter.current();

        const bytesToCopy = @min(segment.len, bytesLeftToWrite);
        // We shouldn't ever allow empty segments (I think?).
        std.debug.assert(bytesToCopy > 0);

        if (reverseBytes)
        {
            for (0 .. bytesToCopy) |i|
            {
                resultBytes[bytesLeftToWrite - 1 - i] = segment[i];
            }
        }
        else
        {
            @memcpy(
                resultBytes[size - bytesLeftToWrite .. bytesToCopy],
                segment[0 .. bytesToCopy]);
        }

        bytesLeftToWrite -= bytesToCopy;
        if (bytesLeftToWrite == 0)
        {
            const newStart = iter.getCurrentPosition().add(bytesToCopy);
            sequence.* = sequence.sliceFrom(newStart);
            return resultBytes;
        }

        if (!iter.advance())
        {
            unreachable;
        }
    }
}


