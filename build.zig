const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zinc", .{
        .root_source_file = b.path("src/zinc.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add url dependency
    const url = b.dependency("url", .{});
    module.addImport("url", url.module("url"));

    const aio_dep = b.dependency("aio", .{});
    module.addImport("aio", aio_dep.module("aio"));

    // Add tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zinc_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("url", url.module("url"));
    unit_tests.root_module.addImport("aio", aio_dep.module("aio"));
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
