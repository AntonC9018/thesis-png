const std = @import("std");

const Error = std.mem.Allocator.Error;

pub fn TaggedArrayListUnmanaged(TaggedUnion: type) type
{
    const Tag = std.meta.Tag(TaggedUnion);
    const Index = std.meta.Int(.unsigned, @bitSizeOf(usize) - @bitSizeOf(Tag));
    const Arrays = Arrays:
    {
        const unionFields = std.meta.fields(TaggedUnion);
        const Struct = std.builtin.Type.Struct;
        const StructField = std.builtin.Type.StructField;
        var fields: [unionFields.len]StructField = undefined;
        for (&fields, unionFields) |*f, u|
        {
            const Array = std.ArrayListUnmanaged(u.type);
            f.* = StructField
            {
                .alignment = if (@sizeOf(Array) > 0) @alignOf(Array) else 0,
                .default_value = &Array{},
                .is_comptime = false,
                .name = u.name,
                .type = Array,
            };
        }
        const s = Struct
        {
            .fields = &fields,
            .backing_integer = null,
            .decls = &.{},
            .is_tuple = false,
            .layout = .Auto,
        };
        break :Arrays @Type(.{
            .Struct = s,
        });
    };
    return struct
    {
        arrays: Arrays = .{},

        pub const Id = packed struct
        {
            tag: Tag,
            index: Index,

            pub fn eql(a: Id, b: Id) bool
            {
                return std.meta.eql(a, b);
            }
        };

        const Self = @This();

        fn ArrayTypeByTag(comptime tag: Tag) type
        {
            return std.meta.fields(Arrays)[@intFromEnum(tag)].type;
        }

        fn getArray(self: *Self, comptime tag: Tag) *ArrayTypeByTag(tag)
        {
            const list = &@field(self.arrays, @tagName(tag));
            return list;
        }

        pub fn append(self: *Self, allocator: std.mem.Allocator, item: TaggedUnion) Error!Id
        {
            switch (item)
            {
                inline else => |value, tag|
                {
                    const array = getArray(self, tag);
                    const index = array.items.len;
                    try array.append(allocator, value);
                    return .{
                        .tag = tag,
                        .index = @intCast(index),
                    };
                }
            }
        }

        pub fn get(self: *Self, id: Id) TaggedUnion
        {
            switch (id.tag)
            {
                inline else => |tag|
                {
                    const array = getArray(self, tag);
                    const value = array.items[id.index];
                    return @unionInit(TaggedUnion, @tagName(tag), value);
                }
            }
        }

        pub fn set(self: *Self, id: Id, value: TaggedUnion) void
        {
            std.debug.assert(id.tag == std.meta.activeTag(value));
            switch (value)
            {
                inline else => |value_, tag|
                {
                    const array = getArray(self, tag);
                    array.items[id.index] = value_;
                }
            }
        }
    };
}

pub fn TaggedArrayList(TaggedUnion: type) type
{
    const Managed = TaggedArrayListUnmanaged(TaggedUnion); 
    return struct
    {
        managed: Managed,
        allocator: std.mem.Allocator,

        pub const Id = Managed.Id;
        const Self = @This();

        pub fn append(self: *Self, item: TaggedUnion) Error!Id
        {
            return self.managed.append(self.allocator, item);
        }

        pub fn get(self: *Self, id: Id) TaggedUnion
        {
            return self.managed.get(id);
        }

        pub fn set(self: *Self, id: Id, value: TaggedUnion) void
        {
            self.managed.set(id, value);
        }

        pub fn init(allocator: std.mem.Allocator) Self
        {
            return .{
                .managed = .{},
                .allocator = allocator,
            };
        }
    };
}
