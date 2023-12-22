const std = @import("std");

pub const SequencePosition = struct {
    segment: u32,
    position: u32,

    pub fn add(self: SequencePosition, offset: u32) SequencePosition
    {
        return .{
            .segment = self.segment,
            .position = self.position + offset,
        };
    }

    pub const Start = SequencePosition { 
        .position = 0,
        .segment = 0,
    };
    pub const End = SequencePosition { 
        .position = std.math.maxInt(usize), 
        .segment = std.math.maxInt(usize),
    };
};

pub const Segment = struct 
{
    array: []const u8,
    len: u32,

    pub fn getSlice(self: *const Segment) []const u8
    {
        return self.array[0 .. self.len];
    }

    pub fn isLastSegment(self: *const Segment) bool
    {
        return self.len < self.array.len;
    }
};

pub const BufferSlice = struct
{
    segments: []const Segment,
    segmentAbsolutePositions: []const usize,
    firstSegmentOffset: usize,
    
    fn getFirstSegmentOffset(self: *const BufferSlice) usize
    {
        return self.firstSegmentOffset;
    }

    fn getSegmentIndex(self: *const BufferSlice, segmentIndex: u32) usize
    {
        return self.getFirstSegmentOffset() + segmentIndex;
    }

    pub fn getSegment(self: *const BufferSlice, segmentIndex: u32) []const u8
    {
        const actualIndex = getSegmentIndex(self, segmentIndex);
        std.debug.assert(actualIndex < self.segments.len);
        return self.segments[actualIndex].getSlice();
    }

    pub fn getAbsolutePosition(self: *const BufferSlice, position: SequencePosition) usize
    {
        const actualIndex = getSegmentIndex(self, position.segment);
        std.debug.assert(actualIndex < self.segmentAbsolutePositions.len);
        const segmentPosition = self.segmentAbsolutePositions[actualIndex];
        return segmentPosition + position.position;
    }
};

pub const Buffer = struct 
{
    segments: std.ArrayListUnmanaged(Segment),
    segmentAbsolutePositions: std.ArrayListUnmanaged(usize), // TODO: Make this dynamic

    pub fn slice(self: *const Buffer) BufferSlice
    {
        const i = self.getFirstSegmentOffset();
        return .{
            .segments = self.segments.items,
            .segmentAbsolutePositions = self.segmentAbsolutePositions.items[i .. ],
            .firstSegmentOffset = i,
        };
    }

    fn getFirstSegmentOffset(self: *const Buffer) usize
    {
        return self.segmentAbsolutePositions.items.len - self.segments.items.len;
    }

    pub fn getSegment(self: *const Buffer, segmentIndex: u32) []const u8
    {
        return self.slice().getSegment(segmentIndex);
    }

    pub fn getAbsolutePosition(self: *const Buffer, position: SequencePosition) usize
    {
        const segmentPosition = self.segmentAbsolutePositions.items[position.segment];
        return segmentPosition + position.position;
    }

    pub fn allByteCount(self: *const Buffer) usize
    {
        const segments_ = self.segments.items;
        const lastSegment = segments_[segments_.len - 1];

        const absolutePositions_ = self.segmentAbsolutePositions.items;
        const lastSegmentAbsolutePosition = absolutePositions_[absolutePositions_.len - 1];

        const lastSegmentEnd = lastSegmentAbsolutePosition + lastSegment.len;
        return lastSegmentEnd;
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
        if (newStart) |s|
        {
            std.debug.assert(s.segment >= self.start.segment);
            std.debug.assert(s.position >= self.start.position);
        }
        if (newEnd) |e|
        {
            std.debug.assert(e.segment <= self.end.segment);
            std.debug.assert(e.position <= self.end.position);
        }

        const start_ = newStart orelse self.start;
        const end_ = newEnd orelse self.end;

        std.debug.assert(start_.position <= end_.position);
        std.debug.assert(start_.segment <= end_.segment);

        return SequenceRange {
            .start = start_,
            .end = end_,
        };
    }
};

pub const Sequence = struct 
{
    buffer: BufferSlice,
    range: SequenceRange,

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
        const start_ = self.start();
        const end_ = self.end();
        const startAbsolute = self.buffer.getAbsolutePosition(start_);
        const endAbsolute = self.buffer.getAbsolutePosition(end_);
        return endAbsolute - startAbsolute;
    }

    pub fn slice(
        self: Sequence,
        range: SequenceRange) Sequence
    {
        if (range.end == SequencePosition.End)
        {
            range.end = self.end();
        }
        if (range.start == SequencePosition.Start)
        {
            range.start = self.start();
        }
        else if (range.start.segment != range.end.segment)
        {
            const startSegment = self.buffer.getSegment(range.start.segment);
            if (range.start.position == startSegment.len)
            {
                range.start.segment += 1;
                range.start.position = 0;
            }
        }
        return .{
            .buffer = self.buffer,
            .range = range,
        };
    }

    pub fn removeFront(self: *Sequence, string: []const u8) RemoveResult
    {
        var string_ = string;
        if (string_.len == 0)
        {
            return RemoveResult.Removed;
        }

        var iter = SegmentIterator.create(self);
        while (true)
        {
            const currentPosition = iter.getCurrentPosition();
            if (iter.next()) |segment|
            {
                const bytesToCheck: u32 = @intCast(@min(segment.len, string_.len));
                for (0 .. bytesToCheck) |i|
                {
                    const a = segment[i];
                    const b = string_[i];
                    if (a != b)
                    {
                        self.range.start = currentPosition.add(@intCast(i));
                        return .NoMatch;
                    }
                }
                string_ = string_[bytesToCheck .. string_.len];
                if (string_.len == 0)
                {
                    self.range.start = currentPosition.add(bytesToCheck);
                    return .Removed;
                }
            }
            else
            {
                self.range.start = self.range.end;
                return .NotEnoughBytes;
            }
        }
    }
};

pub const RemoveResult = enum {
    NotEnoughBytes,
    Removed,
    NoMatch,
};

pub const SegmentIterator = struct {
    sequence: *const Sequence,
    currentPosition: SequencePosition,

    pub fn create(sequence: *const Sequence) SegmentIterator
    {
        return .{
            .sequence = sequence,
            .currentPosition = sequence.start(),
        };
    }

    pub fn getCurrentPosition(self: *SegmentIterator) SequencePosition
    {
        return self.currentPosition;
    }

    pub fn next(self: *SegmentIterator) ?[] const u8
    {
        const start_ = &self.currentPosition;
        const end_ = self.sequence.end();
        if (start_.segment > end_.segment)
        {
            return null;
        }

        defer {
            start_.segment += 1;
            start_.position = 0;
        }

        const segment = self.sequence.buffer.getSegment(start_.segment);
        if (start_.segment == end_.segment)
        {
            return segment[start_.position .. end_.position];
        }
        else
        {
            return segment[start_.position .. segment.len];
        }
    }
};

pub const ReaderResult = struct 
{
    isEnd: bool,
    sequence: Sequence,
};

pub fn Reader(comptime ReaderType: type) type 
{
    return struct
    {
        const Self = @This();

        defaultBufferSize: usize,
        allocator: std.mem.Allocator,
        reader: ReaderType,

        _buffer: Buffer,
        _firstBufferStart: u32,
        _selectLastBufferEnd: u32,

        fn readOneMoreSegment(self: *Self) !Segment
        {
            const newBuffer = self.allocator.alloc(u8, self.defaultBufferSize);
            errdefer self.allocator.free(newBuffer);

            // TODO: When decoupled from the writer, this should just pause the thread.
            const readCount = try self.reader.read(newBuffer);

            return .{
                .array = newBuffer[0 .. readCount],
                .len = readCount,
            };
        }

        fn currentSequence(self: *Self) Sequence
        {
            const buffer_ = self.buffer();
            return .{
                .buffer = buffer_.slice(),
                .range = .{
                    .start = .{ 
                        .segment = buffer_.getFirstSegmentOffset(),
                        .position = self._firstBufferStart,
                    },
                    .end = .{ 
                        .segment = buffer_.segments.len - 1 + buffer_.getFirstSegmentOffset(),
                        .position = self._selectLastBufferEnd,
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
            consumedPosition: ?SequencePosition,
            readPosition: ?SequencePosition) !void
        {
            const buffer_ = self.buffer();

            const sequence_ = self.currentSequence();
            const range = sequence_.range.slice(consumedPosition, readPosition); 
            const newSequence = sequence_.slice(range);
            const shouldAddNewSegment = newSequence.len() < self.defaultBufferSize;

            // Removed segments = from current start until the new start segment.
            {
                const newStart = newSequence.start();
                const currentStart = sequence_.start();
                const removedSegmentsCount = newStart.segment - currentStart.segment;

                const segments = &buffer_.segments;
                for (0 .. removedSegmentsCount) |i|
                {
                    self.allocator.free(segments[i].array);
                    segments[i] = segments[i + removedSegmentsCount];
                }
                segments.len -= removedSegmentsCount;
            }

            if (shouldAddNewSegment)
            {
                const newSegment = try self.readOneMoreSegment();
                errdefer self.allocator.free(newSegment.array);

                const newSegmentMemory = try buffer_.segments.append(newSegment, self.allocator);
                newSegmentMemory.* = newSegment;

                buffer_.segmentAbsolutePositions.append(buffer_.allByteCount());
            }

            self._selectLastBufferEnd = newSequence.end().position;
            self._firstBufferStart = newSequence.start().position;
        }

        pub fn read(self: *Self) ReaderResult
        {
            const buffer_ = self.buffer();
            const segments = buffer_.segments;
            return .{
                .isEnd = segments[segments.len - 1].isLastSegment(),
                .sequence = self.currentSequence(),
            };
        }
    };
}
    