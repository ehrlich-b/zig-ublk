const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module - exposed for other packages to import
    const lib_mod = b.addModule("zig_ublk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Unit tests for the library
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // Example: null device
    const example_null = b.addExecutable(.{
        .name = "example-null",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/null.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_ublk", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(example_null);

    const run_example_null = b.addRunArtifact(example_null);
    const run_example_null_step = b.step("run-example-null", "Run the null device example");
    run_example_null_step.dependOn(&run_example_null.step);

    // Example: memory device (RAM disk)
    const example_memory = b.addExecutable(.{
        .name = "example-memory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/memory.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_ublk", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(example_memory);

    const run_example_memory = b.addRunArtifact(example_memory);
    const run_example_memory_step = b.step("run-example-memory", "Run the memory device example");
    run_example_memory_step.dependOn(&run_example_memory.step);

    // Example: null device (benchmark version)
    const example_null_bench = b.addExecutable(.{
        .name = "example-null-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/null_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Always optimized for benchmarking
            .imports = &.{
                .{ .name = "zig_ublk", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(example_null_bench);
}
