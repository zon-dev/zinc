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
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addImport("url", url.module("url"));
    unit_tests.root_module.addImport("aio", aio_dep.module("aio"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    // `addRunArtifact` puts tests in server mode (stdio = zig_test). Results
    // then only appear in `zig build --summary`, whose default is `failures` —
    // so a fully green run prints nothing. Inherit the default test runner's
    // terminal output instead ("All N tests passed.").
    run_unit_tests.test_runner_mode = false;
    run_unit_tests.stdio = .inherit;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ReleaseFast + `perf:` filter. Debug `zig build test` still runs the same
    // cases with lower floors; this step is the throughput regression gate.
    const perf_tests = b.addTest(.{
        .name = "perf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zinc_test.zig"),
            .target = b.graph.host,
            .optimize = .fast,
            .link_libc = true,
        }),
        .filters = &.{"perf:"},
    });
    perf_tests.root_module.addImport("url", url.module("url"));
    perf_tests.root_module.addImport("aio", aio_dep.module("aio"));

    const run_perf_tests = b.addRunArtifact(perf_tests);
    run_perf_tests.test_runner_mode = false;
    run_perf_tests.stdio = .inherit;

    const perf_step = b.step("perf", "Run performance regression tests (ReleaseFast)");
    perf_step.dependOn(&run_perf_tests.step);
}
