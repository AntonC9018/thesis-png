const std = @import("std");

pub const SequencePosition = struct
{
    segment: *const Segment,
    offset: u32,

    // TODO:
    // Maybe add this later.
    // This would make the length calculations not have to walk over the segments.
    // offsetRelativeToStart: u32,

    pub fn add(self: SequencePosition, offset: u32) SequencePosition
    {
        return .{
            .segment = self.segment,
            .offset = self.offset + offset,
        };
    }

    pub fn getBytePosition(self: *const SequencePosition) usize
    {
        return self.segment.getBytePosition() + self.offset;
    }

    pub const StartSentinelSegment = std.mem.zeroes(Segment);
    pub const EndSentinelSegment = std.mem.zeroes(Segment);

    pub const Start = SequencePosition
    { 
        .offset = 0,
        .segment = &StartSentinelSegment,
    };
    pub const End = SequencePosition
    { 
        .offset = std.math.maxInt(u32), 
        .segment = &EndSentinelSegment,
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

// pub const BufferSegment = struct
// {
// };

pub const SegmentData = struct
{
    items: []const u8,
    // TODO: This shouldn't be here.
    capacity: usize = 0,
    bytePosition: usize,
};

pub const Segment = struct 
{
    data: SegmentData,
    // The next segment is not necesserily going to be stored in the array.
    // We want the flexibility of being able to hijack the sequence without
    // storing the data in the buffer manager.
    // TODO:
    // Maybe move the list part to a separate array
    // to make it easier to hijack the sequence.
    nextSegment: ?*Segment,

    // So this should also have some tag to indicate where it's from?
    // origin: *anyopaque,

    pub fn underlyingArray(self: *const Segment) []const u8
    {
        const d = &self.data;
        return d.items.ptr[0 .. d.capacity];
    }

    pub fn len(self: *const Segment) u32
    {
        return @intCast(self.data.items.len);
    }

    pub fn bytePosition(self: *const Segment) usize
    {
        return self.data.bytePosition;
    }

    pub fn getSlice(self: *const Segment) []const u8
    {
        return self.data.items;
    }

    pub fn getBytePosition(self: *const Segment) usize
    {
        return self.bytePosition();
    }
};

fn ptrSub(a: anytype, b: @TypeOf(a)) usize
{
    return @divExact(@intFromPtr(a) - @intFromPtr(b), @sizeOf(@TypeOf(a))); 
}

pub const BufferManager = struct 
{
    segments: std.ArrayListUnmanaged(Segment),
    totalBytes: usize,

    // It's not going to delete data below this lower limit.
    lowerLimitHint: ?usize = null,

    fn getFirstSegment(self: *const BufferManager) *const Segment
    {
        const s = self.segments.items;
        if (s.len == 0)
        {
            return &SequencePosition.StartSentinelSegment;
        }
        return &s[0];
    }

    pub fn getBytePosition(self: *const BufferManager, position: SequencePosition) usize
    {
        const segments_ = self.segments.items;
        if (segments_.len == 0)
        {
            return self.totalBytes;
        }

        const actualIndex = self.getSegmentIndex(position.segment);
        return segments_[actualIndex].getBytePosition() + position.offset;
    }

    pub fn allByteCount(self: *const BufferManager) usize
    {
        return self.totalBytes;
    }

    pub fn appendSegment(
        self: *BufferManager,
        segment: Segment,
        allocator: std.mem.Allocator) !void
    {
        try self.segments.append(allocator, segment);
        self.totalBytes += segment.len();

        // Let's update the list here for now.
        const s_ = self.segments.items;
        if (s_.len >= 2)
        {
            s_[s_.len - 2].nextSegment = &s_[s_.len - 1];
        }
    }

    // Returns the newStart position, projected on the updated segments array.
    pub fn cleanUpUnneededSegments(
        self: *BufferManager,
        allocator: std.mem.Allocator,
        newStart: SequencePosition) SequencePosition
    {
        if (self.segments.items.len == 0)
        {
            return newStart;
        }
        else if (newStart.segment == &SequencePosition.StartSentinelSegment)
        {
            return .{
                .offset = 0,
                .segment = &self.segments.items[0],
            };
        }

        const firstSegmentToKeepInMemory = if (self.lowerLimitHint) |hint|
        hint:
        {
            // TODO: Maybe binary search?
            for (0 .., self.segments.items) |i, *s|
            {
                if (s.getBytePosition() + s.len() > hint)
                {
                    break :hint i;
                }
            }
            // This means the specified byte position is already outside the segment space.
            unreachable;
        } 
        else null;

        const newStartSegmentIndex, const shouldResetOffset = segmentIndexOfStart:
        {
            if (newStart.segment == &SequencePosition.EndSentinelSegment)
            {
                break :segmentIndexOfStart .{ self.segments.items.len, true };
            }

            const startAddress = &self.segments.items[0];
            const targetAddress = newStart.segment;
            const index = ptrSub(targetAddress, startAddress);

            const isAtEndOfSegment = newStart.offset == newStart.segment.len();
            if (isAtEndOfSegment)
            {
                break :segmentIndexOfStart .{ index + 1, true };
            }
            break :segmentIndexOfStart .{ index, false };
        };

        const deleteUntilSegmentIndex = if (firstSegmentToKeepInMemory) |s|
                @min(newStartSegmentIndex, s)
            else
                newStartSegmentIndex;

        if (deleteUntilSegmentIndex == 0)
        {
            return newStart;
        }

        const segs = &self.segments.items;
        // Removed segments = from current start until the new start segment.
        for (segs.*[0 .. deleteUntilSegmentIndex]) |*s|
        {
            allocator.free(s.underlyingArray());
        }
        for (deleteUntilSegmentIndex .. segs.len) |i|
        {
            segs.*[i - deleteUntilSegmentIndex] = segs.*[i];
        }
        segs.len -= deleteUntilSegmentIndex;

        if (segs.len == 0)
        {
            return SequencePosition.Start;
        }

        restoreConsecutiveLinks(segs.*[(deleteUntilSegmentIndex - 1) .. segs.len]);

        const index = newStartSegmentIndex - deleteUntilSegmentIndex;
        return .{
            .offset = if (shouldResetOffset) 0 else newStart.offset,
            .segment = &segs.*[index],
        };
    }

    const SegmentNotInMemoryErrorType = error{SegmentNotInMemory};

    pub fn getSegmentForRange(
        self: *const BufferManager,
        range: ByteRange) Sequence
    {
        if (range.end < range.start)
        {
            unreachable;
        }
        const segs = self.segments.items;
        if (segs.len == 0)
        {
            return Sequence.createEmpty(self);
        }

        const start = start:
        {
            for (0 .., segs) |i, *s|
            {
                if (s.getBytePosition() + s.len() > range.start)
                {
                    break :start i;
                }
            }
            break :start null;
        };
        const end = end:
        {
            const startIndex = start orelse break :end null;

            for (startIndex .., segs[startIndex .. segs.len]) |i, *s|
            {
                if (s.getBytePosition() + s.len() >= range.end)
                {
                    break :end i;
                }
            }
            break :end null;
        };
        const maybeEnd = struct
        {
            fn f(segs_: []const Segment, index: ?usize, pos: usize) SequencePosition
            {
                if (index) |index_|
                {
                    const s = &segs_[index_];
                    const offset = pos -| s.getBytePosition();
                    return .{
                        .offset = @intCast(offset),
                        .segment = s,
                    };
                }
                else
                {
                    // Then it's past the end.
                    const s = &segs_[segs_.len - 1];
                    const offset = s.len();
                    return .{
                        .offset = @intCast(offset),
                        .segment = s,
                    };
                }
            }
        }.f;

        const startSequencePosition = maybeEnd(segs, start, range.start);
        const endSequencePosition = endPos:
        {
            if (start == null)
            {
                std.debug.assert(end == null);
                break :endPos startSequencePosition;
            }
            break :endPos maybeEnd(segs, end, range.end);
        };
        const wholeSequence = Sequence.create(self);
        const sequenceRange = wholeSequence.range.slice(.{
            .start = startSequencePosition,
            .end = endSequencePosition,
        });
        return wholeSequence.slice(sequenceRange);
    }

    pub fn deinit(self: BufferManager, allocator: std.mem.Allocator) void
    {
        for (self.segments.items) |s|
        {
            allocator.free(s.data.items.ptr[0 .. s.data.capacity]);
        }
    }
};

pub const ByteRange = struct
{
    start: usize,
    end: usize,
};

pub const SequenceRange = struct
{
    start: SequencePosition,

    // exclusive.
    end: SequencePosition,

    len: u32,

    pub fn slice(
        self: *const SequenceRange,
        range:
            struct
            {
                start: ?SequencePosition = null,
                end: ?SequencePosition = null,
            }) SequenceRange 
    {
        var start_ = range.start orelse self.start;
        var end_ = range.end orelse self.end;

        const local = struct
        {
            fn collapseEnds(s: *const SequenceRange, pos: *SequencePosition) void
            {
                if (bytesEqual(pos.*, SequencePosition.End))
                {
                    pos.* = s.end;
                }
                else if (bytesEqual(pos.*, SequencePosition.Start))
                {
                    pos.* = s.start;
                }
            }
        };
        local.collapseEnds(self, &start_);
        local.collapseEnds(self, &end_);

        if (start_.segment == end_.segment)
        {
            std.debug.assert(start_.offset <= end_.offset);
        }

        const len_ = len:
        {
            if (start_.segment == self.start.segment
                and end_.segment == self.end.segment)
            {
                const removedLeft = start_.offset - self.start.offset;
                const removedRight = self.end.offset - end_.offset;
                const removed = removedLeft + removedRight;
                break :len self.len - removed;
            }

            if (start_.segment == end_.segment)
            {
                break :len end_.offset - start_.offset;
            }

            // Could also make this potentially more optimal
            // by walking from the old start to the new start,
            // and then from the old end to the new end.
            var lenAccum = start_.segment.len() - start_.offset;
            if (start_.segment.nextSegment) |secondSegment|
            {
                var current = secondSegment;
                while (current != end_.segment)
                {
                    lenAccum += current.len();
                    current = current.nextSegment.?;
                }
            }
            lenAccum += end_.offset;
            break :len lenAccum;
        };

        return SequenceRange
        {
            .start = start_,
            .end = end_,
            .len = len_,
        };
    }
};

pub const Sequence = struct 
{
    range: SequenceRange,

    pub fn createEmpty(buffer: *const BufferManager) Sequence
    {
        const pos = SequencePosition
        {
            .offset = 0,
            .segment = buffer.getFirstSegment(),
        };
        return .{
            .range = .{
                .start = pos,
                .end = pos,
                .len = 0,
            },
        };
    }

    pub fn create(buffer: *const BufferManager) Sequence
    {
        const segments_ = buffer.segments.items;
        if (segments_.len == 0)
        {
            return Sequence.createEmpty(buffer);
        }

        const start_ = SequencePosition
        {
            .offset = 0,
            .segment = buffer.getFirstSegment(),
        };
        const lastSegment_ = &segments_[segments_.len - 1];
        const end_ = SequencePosition
        {
            .offset = lastSegment_.len(),
            .segment = lastSegment_,
        };
        const totalLength = lastSegment_.bytePosition() + lastSegment_.len() - segments_[0].bytePosition();
        return .{
            .range = .{
                .start = start_,
                .end = end_,
                .len = @intCast(totalLength),
            },
        };
    }

    pub fn start(self: *const Sequence) SequencePosition 
    {
        return self.range.start;
    }

    pub fn end(self: *const Sequence) SequencePosition 
    {
        return self.range.end;
    }

    pub fn len(self: *const Sequence) usize
    {
        // Has to be O(N), so it's cached in the range.
        return self.range.len;
    }

    pub fn isEmpty(self: *const Sequence) bool
    {
        return self.len() == 0;
    }

    pub fn getStartBytePosition(self: *const Sequence) usize
    {
        return self.start().getBytePosition();
    }

    pub fn getPosition(self: *const Sequence, offset: usize) SequencePosition
    {
        std.debug.assert(offset <= self.len());

        if (offset == 0)
        {
            return self.start();
        }

        var leftToMove: usize = offset;
        var current = self.start().segment;
        var offset_ = self.start().offset;
        // let's just linearly search for now.
        while (true)
        {
            const willMoveAmount = @min(leftToMove, current.len() - offset_);
            leftToMove -= willMoveAmount;

            if (leftToMove == 0)
            {
                return .{
                    .segment = current,
                    .offset = @intCast(offset_ + willMoveAmount),
                };
            }
            offset_ = 0;
            current = current.nextSegment.?;
        }

        unreachable;
    }

    fn getWholeSegmentCount(self: *const Sequence) u32
    {
        const start_ = self.start();
        const end_ = self.end();
        var counter: u32 = 0;
        var current = start_.segment;
        while (current != end_.segment)
        {
            counter += 1;
            current = current.nextSegment.?;
        }
        if (end_.segment.len() == end_.offset)
        {
            counter += 1;
        }
        return counter;
    }

    pub fn sliceFrom(self: *const Sequence, newStart: SequencePosition) Sequence
    {
        const newRange = self.range.slice(.{
            .start = newStart,
            .end = self.end(),
        });
        return self.slice(newRange);
    }

    pub fn sliceToExclusive(self: *const Sequence, newEnd: SequencePosition) Sequence
    {
        const newRange = self.range.slice(.{
            .start = self.start(),
            .end = newEnd,
        });
        return self.slice(newRange);
    }

    // Creates two slices:
    // One up to the middle position, exclusive.
    // Second from the middle position, inclusive.
    pub fn disect(self: *const Sequence, middle: SequencePosition) 
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
        self: *const Sequence,
        range: SequenceRange) Sequence
    {
        var range_ = range;


        const willMoveEnd = range_.end.offset == 0 and range.end.segment != self.start().segment;

        // Collapse the end position of the range into the previous segment if the offset is 0.
        if (willMoveEnd)
        {
            // For this, we need to find the end segment.
            // TODO: Is this ever hit, actually?
            unreachable;

            // const endSegment = self.segments.getSegment(range_.end.segment - 1);
            // range_.end.segment -= 1;
            // range_.end.offset = @intCast(endSegment.len);
        }

        // If the start happened to go past the end, 
        // it's either an error, which we check with an assert,
        // or it happens to be the same position as the end after we move it into the previous segment.
        // TODO: Maybe allow empty segments? The all of these just have to be while loops.
        if (range_.start.segment == range_.end.segment.nextSegment)
        {
            std.debug.assert(range_.start.offset == 0);

            // The position has to overlap exactly with the end position.
            const endSegment = range_.end.segment;
            std.debug.assert(range_.end.offset == endSegment.len());

            range_.start.segment = range_.end.segment;
            // Empty segment that starts and ends at the end of the single segment.
            range_.start.offset = @intCast(endSegment.len());
        }

        // Need to normalize the slice.

        // If they ended up in the same segment, we keep them as is.

        // Else, they are at least 1 segment apart.
        // If they are exactly 1 segment apart, need need to be careful to make sure
        // the start doesn't go past the end.
        if (range_.end.segment != range_.start.segment)
        {
            const startSegment = range_.start.segment;
            const startWillBeMoved = range_.start.offset == startSegment.len();
            const areInSameSegment = range_.end.segment == startSegment.nextSegment;
            const dontMoveStart = areInSameSegment and willMoveEnd;

            if (startWillBeMoved and !dontMoveStart)
            {
                range_.start.segment = range_.end.segment;
                range_.start.offset = 0;
            }
        }

        return .{
            .range = range_,
        };
    }

    pub fn copyTo(self: *const Sequence, buffer: []u8) void
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

    pub fn getFirstSegment(self: *const Sequence) []const u8
    {
        const start_ = self.start();
        const wholeSegment = start_.segment;
        return wholeSegment.getSlice()[start_.offset ..];
    }

    pub fn peekFirstByte(self: *const Sequence) ?u8
    {
        if (self.isEmpty())
        {
            return null;
        }
        const firstSegment = self.getFirstSegment();
        return firstSegment[0];
    }

    pub fn debugPrint(self: *const Sequence) void
    {
        const allocator = std.heap.page_allocator;
        const mem = allocator.alloc(u8, self.len()) catch unreachable;
        defer allocator.free(mem);
        self.copyTo(mem);
        std.debug.print("Sequence: {s}\n", .{mem});
    }

    pub fn iterate(self: *const Sequence) ?SegmentIterator
    {
        return SegmentIterator.create(self);
    }
};

// Segment SegmentIterator begin
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
        const segment = start_.segment;
        if (start_.segment == end_.segment)
        {
            return segment.getSlice()[start_.offset .. end_.offset];
        }
        else
        {
            return segment.getSlice()[start_.offset ..];
        }
    }

    pub fn advance(self: *SegmentIterator) bool
    {
        // I try to keep the ends in the same segment 
        // such that there are no empty segments.
        // So this should be correct.
        const currentSegment = self.currentPosition.segment;
        const movedPastEnd = currentSegment == self.sequence.end().segment;
        if (movedPastEnd)
        {
            self.currentPosition = SequencePosition.End;
            return false;
        }
        else
        {
            const nextSegment = currentSegment.nextSegment;
            self.currentPosition.segment = nextSegment.?;
            self.currentPosition.offset = 0;
            return true;
        }
    }

    pub fn getCurrentPosition(self: *SegmentIterator) SequencePosition
    {
        return self.currentPosition;
    }
};
// Segment SegmentIterator end

pub const ReaderResult = struct 
{
    isEnd: bool,
    sequence: Sequence,
};

pub const AdvanceRange = struct
{
    consumed: ?SequencePosition = null,
    examined: ?SequencePosition = null,
};

const EOFState = enum {
    FirstRead,
    NotReached,
    Reached,
    AlreadySignaled,
};

pub fn Reader(ReaderType: type) type 
{
    return struct
    {
        const Self = @This();

        preferredBufferSize: usize,
        allocator: std.mem.Allocator,
        dataProvider: ReaderType,

        _buffer: BufferManager = std.mem.zeroes(BufferManager),
        _consumedUntilPosition: SequencePosition = SequencePosition.Start,
        _eofState: EOFState = .FirstRead,

        pub fn deinit(self: *Self) void
        {
            for (self._buffer.segments.items) |*s|
            {
                self.allocator.free(s.underlyingArray());
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

            const s = Segment
            {
                .data = .{
                    .items = newBuffer[0 .. readCount],
                    .capacity = newBuffer.len,
                    .bytePosition = self._buffer.allByteCount(),
                },
                .nextSegment = null,
            };
            // TODO:
            // I think it is possible to get an empty segment this way.
            // We have to signal whether we are done from the data provider.
            // That should be possible with files.
            // Or we have to be careful with empty chunks at the end, to not have things break.
            if (newBuffer.len > readCount)
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
            const wholeSequence = Sequence.create(buffer_);
            const result = wholeSequence.sliceFrom(self._consumedUntilPosition);
            return result;
        }

        pub fn buffer(self: *Self) *BufferManager
        {
            return &self._buffer;
        }

        pub fn advance(
            self: *Self,
            consumedPosition: ?SequencePosition) !void
        {
            const desiredStart = consumedPosition orelse self.currentSequence().start();

            const newStartPosition = self.buffer()
                .cleanUpUnneededSegments(self.allocator, desiredStart);

            if (self._eofState == .NotReached)
            {
                const newSegment = try self.readOneMoreSegment();
                errdefer self.allocator.free(newSegment.underlyingArray());

                // You should only call advance once you've scanned all of the input.
                // Or you know you need more.
                try self.buffer().appendSegment(newSegment, self.allocator);
            }

            self._consumedUntilPosition = newStartPosition;
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
                errdefer self.allocator.free(newSegment.underlyingArray());

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

pub const TestDataProvider = struct
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

fn restoreConsecutiveLinks(segments: []Segment) void
{
    if (segments.len >= 2)
    {
        for (segments[0 .. segments.len - 1], segments[1 ..]) |*s0, *s1|
        {
            s0.nextSegment = s1;
        }
    }
    if (segments.len >= 1)
    {
        segments[segments.len - 1].nextSegment = null;
    }
}

pub fn createTestBufferFromData(
    data: []const []const u8,
    allocator: std.mem.Allocator) !BufferManager
{
    var segments = std.ArrayListUnmanaged(Segment){};
    try segments.ensureTotalCapacity(allocator, data.len);
    segments.items.len = data.len;

    var length: usize = 0;
    for (data, segments.items) |data_, *s|
    {
        s.* = Segment
        {
            .data = .{
                .items = data_,
                .capacity = data_.len,
                .bytePosition = length,
            },
            .nextSegment = null,
        };
        length += data_.len;
    }
    restoreConsecutiveLinks(segments.items);

    return .{
        .segments = segments,
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
        var iter = firstSegment.iterate().?;
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
        const sequence = wholeSequence.slice(
            wholeSequence.range.slice(.{
                .start = wholeSequence.getPosition(1),
                .end = wholeSequence.getPosition(5),
            }));

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
        const iter = reader.currentSequence().iterate();
        try t.expect(iter == null);
    }
    {
        const readResult = try reader.read();
        var iter = readResult.sequence.iterate().?;
        try t.expectEqualStrings("0123", iter.current());
        try t.expect(!iter.advance());
    }
    try reader.advance(null);
    {
        const readResult = try reader.read();
        {
            try t.expectEqual(2, reader.buffer().segments.items.len);

            var iter = readResult.sequence.iterate().?;
            try t.expectEqualStrings("0123", iter.current());
            try t.expect(iter.advance());
            try t.expectEqualStrings("4567", iter.current());
            try t.expect(!iter.advance());
        }
        {
            var sequence = readResult.sequence;
            sequence = sequence.sliceFrom(sequence.getPosition(2));

            var iter = sequence.iterate().?;
            try t.expectEqualStrings("23", iter.current());
            try t.expect(iter.advance());
            try t.expectEqualStrings("4567", iter.current());
            try t.expect(!iter.advance());
        }
        {
            var sequence = readResult.sequence;
            sequence = sequence.slice(
                sequence.range.slice(.{
                    .start = sequence.getPosition(2),
                    .end = sequence.getPosition(6),
                }));

            var iter = sequence.iterate().?;
            try t.expectEqualStrings("23", iter.current());
            try t.expect(iter.advance());
            try t.expectEqualStrings("45", iter.current());
            try t.expect(!iter.advance());
        }
        {
            var sequence = readResult.sequence;
            sequence = sequence.slice(
                sequence.range.slice(.{
                    .start = sequence.getPosition(2),
                    .end = sequence.getPosition(3),
                }));

            var iter = sequence.iterate().?;
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
        try t.expectEqual(0, sequence.start().offset);
        try t.expectEqual(4, sequence.end().offset);
        try t.expectEqual(sequence.end().segment, sequence.start().segment);
        try t.expectEqual(@as(usize, 4), sequence.len());
        try t.expectEqual(null, sequence.start().segment.nextSegment);

        try setup.check(sequence, "0123");
        
        // None consumed.
        try setup.reader.advance(null);
    }
    {
        const readResult = try setup.reader.read();
        try t.expect(!readResult.isEnd);

        const sequence = readResult.sequence;
        try t.expectEqual(0, sequence.start().offset);
        try t.expectEqual(4, sequence.end().offset);
        try t.expectEqual(sequence.start().segment.nextSegment, sequence.end().segment);
        try t.expectEqual(@as(usize, 8), sequence.len());

        const secondBufferStartPosition = sequence.getPosition(4);
        try setup.check(sequence.sliceToExclusive(secondBufferStartPosition), "0123");

        try setup.check(sequence.sliceFrom(secondBufferStartPosition), "4567");

        try setup.check(sequence, "01234567");

        // Let's remove the first two characters.
        const consumedPosition = sequence.getPosition(2);
        try setup.check(sequence.sliceFrom(consumedPosition), "234567");

        try setup.reader.advance(consumedPosition);
    }
    {
        const readResult = try setup.reader.read();
        try t.expect(readResult.isEnd);

        const sequence = readResult.sequence;
        try setup.check(sequence, "23456789");
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
        try t.expectEqual('0', ch);
        try t.expectEqual(1, r.sequence.getStartBytePosition());
    }
    {
        const ch = try removeFirst(&r.sequence);
        try t.expectEqual('1', ch);
        try t.expectEqual(2, r.sequence.getStartBytePosition());
    }
}

pub fn isLittleEndian() bool
{
    const native_endian = @import("builtin").target.cpu.arch.endian();
    return native_endian == .little; 
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
    const reverseBytes = comptime isLittleEndian();
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


