const std = @import("std");
const pipelines = @import("pipelines.zig");

const raylib = @import("raylib");

const resourcesDir = "raylib/raylib/examples/text/resources/";

// 1. Transform parser results into tree
// 2. Draw bytes on screen
// 3. Draw image
// 4. Visualize the tree
// 5. Allow switching pages changing the current range
// 6. Deleting invisible parts of the tree
//

const ChildrenList = struct
{
    array: std.ArrayListUnmanaged(Node),
};

const NodeType = struct
{
};

const NodeData = struct
{
    type: NodeType,
    value: union(enum)
    {
    },
};

const NodePosition = struct
{
    byte: usize,
    bit: u3,
};

const NodeSpan = struct
{
    start: NodePosition,
    endInclusive: NodePosition,
};

const Node = struct
{
    span: NodePosition,
    nodeData: usize,
    children: ChildrenList,
};

const AST = struct
{
    nodes: std.ArrayList(Node),
    nodeData: std.ArrayList(NodeData),
};

pub fn main() !void
{
    try @import("pngDebug.zig").readTestFile();
}

test
{ 
    _ = pipelines;
    _ = @import("zlib/zlib.zig");
}

