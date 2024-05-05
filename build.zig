const std = @import("std");
const raylib = @import("raylib/build.zig");

pub fn build(b: *std.Build) !void
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "png",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);
    raylib.addTo(b, exe, target.query, optimize, .{});

    {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        // `zig build run -- arg1 arg2 etc`
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const unit_tests = b.addTest(.{
            .name = "png-test",
            .root_source_file = exe.root_module.root_source_file.?,
            .target = target,
            .optimize = optimize,
            .filter = b.option([]const u8, "test-filter", "test filter"),
        });
        b.installArtifact(unit_tests);

        const run_unit_tests = b.addRunArtifact(unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}
