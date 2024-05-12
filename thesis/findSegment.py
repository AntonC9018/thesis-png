import sys

filePath = sys.argv[1]
segmentName = sys.argv[2]
segmentBeginString = "// Segment " + segmentName + " begin"
segmentEndString = "// Segment " + segmentName + " end"

# Search for start and end of segment in the file
segmentBegin = -1
segmentEnd = -1
with open(filePath, "r") as fp:
    index = 0
    for line in fp:
        if segmentBeginString in line:
            segmentBegin = index
        if segmentEndString in line:
            segmentEnd = index
        index += 1

try:
    if segmentBegin == -1 or segmentEnd == -1:
        print(f"Segment {segmentName} not found in file {filePath}")
        exit(-1) # not actually sure this affects the error.

    print(f"\\inputminted[firstline={segmentBegin + 2},lastline={segmentEnd}]{{zig}}{{{filePath}}}", flush=True)

# This error floods the output if you don't close the stderr at the end.
except (BrokenPipeError):
    sys.stderr.close()
