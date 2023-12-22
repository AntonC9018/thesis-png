const std = @import("std");

pub const SequencePosition = struct {
    segment: u32,
    position: u32,

    pub fn add(self: SequencePosition, offset: u32) SequencePosition
    {
        return SequencePosition {
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

pub const Buffer = struct 
{
    segments: [] const [] const u8,
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
    buffer: Buffer,
    range: SequenceRange,

    pub fn start(self: *const Sequence) SequencePosition 
    {
        return self.range.start;
    }

    pub fn end(self: *const Sequence) SequencePosition 
    {
        return self.range.end;
    }

    pub fn isLengthAtLeast(self: *const Sequence, length: i64) bool
    {
        if (length == 0)
        {
            return true;
        }

        const start_ = self.start();
        const end_ = self.end();

        // Single segment special case
        if (start_.segment == end_.segment)
        {
            const singleSegmentLength = end_.position - start_.position;
            return length <= singleSegmentLength;
        }

        // First and last segments might not be complete
        {
            const segment = self.buffer.segments[start_.segment];
            const segmentLength = segment.len - start_.position;
            length -= segmentLength;
            if (length <= 0)
            {
                return true;
            }
        }
        {
            const lastSegmentLength = end_.position;
            length -= lastSegmentLength;
            if (length <= 0)
            {
                return true;
            }
        }

        var currentSegment = start_.segment + 1;
        while (currentSegment < end_.segment)
        {
            const segment = self.buffer.segments[currentSegment];
            const segmentLength = segment.len;
            length -= segmentLength;
            if (length <= 0)
            {
                return true;
            }
            currentSegment += 1;
        }

        return false;
    }

    pub fn len(self: *const Sequence) u61
    {
        const start_ = self.start();
        const end_ = self.end();

        // Single segment special case
        if (start_.segment == end_.segment)
        {
            return end_.position - start_.position;
        }

        // First and last segments might not be complete
        var length = 0;
        {
            const segment = self.buffer.segments[start_.segment];
            const segmentLength = segment.len - start_.position;
            length += segmentLength;
        }

        var currentSegment = start_.segment + 1;
        while (currentSegment < end_.segment)
        {
            const segment = self.buffer.segments[currentSegment];
            const segmentLength = segment.len;
            length += segmentLength;
            currentSegment += 1;
        }

        {
            const lastSegmentLength = end_.position;
            length += lastSegmentLength;
        }

        return length;
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
            std.debug.assert(range.start.segment < self.buffer.segments.len);
            const startSegment = self.buffer.segments[range.start.segment];
            if (range.start.position == startSegment.len)
            {
                range.start.segment += 1;
                range.start.position = 0;
            }
        }
        return Sequence {
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

        var iter = SegmentIterator {
            .current = self.*,
        };

        while (true)
        {
            const currentPosition = iter.getCurrentPosition();
            if (iter.next()) |segment|
            {
                const bytesToCheck: u32 = @intCast(@min(segment.len, string_.len));
                for (0 .. bytesToCheck) |i|
                {
                    if (segment[i] != string_[i])
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
    current: Sequence,

    pub fn getCurrentPosition(self: *SegmentIterator) SequencePosition
    {
        return self.current.start();
    }

    pub fn next(self: *SegmentIterator) ?[] const u8
    {
        const start_ = self.current.start();
        const end_ = self.current.end();
        if (start_.segment > end_.segment)
        {
            return null;
        }

        defer {
            const startPtr = &self.current.range.start;
            startPtr.segment += 1;
            startPtr.position = 0;
        }

        const segment = self.current.buffer.segments[start_.segment];
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

pub const ReaderResult = struct {
    isEnd: bool,
    sequence: Sequence,
};