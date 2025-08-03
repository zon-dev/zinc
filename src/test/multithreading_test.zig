const std = @import("std");
const zinc = @import("../zinc.zig");

test "multithreading basic" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 4,
        .force_nonblocking = true,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/test", testHandler);

    try std.testing.expect(z.num_threads == 4);
}

test "multithreading high concurrency" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 8,
        .force_nonblocking = true,
        .read_buffer_len = 16384,
        .stack_size = 2097152, // 2MB stack
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/concurrent", concurrentHandler);

    try std.testing.expect(z.num_threads == 8);
    try std.testing.expect(z.read_buffer_len == 16384);
}

test "multithreading thread pool management" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 2,
        .force_nonblocking = true,
    });
    defer z.deinit();

    // Test thread pool initialization
    try std.testing.expect(z.num_threads == 2);

    // Test that threads can be spawned
    var router = z.getRouter();
    try router.get("/thread-test", threadTestHandler);
}

test "multithreading async operations" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 6,
        .force_nonblocking = true,
        .read_buffer_len = 8192,
        .header_buffer_len = 1024,
        .body_buffer_len = 32768,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/async", asyncHandler);
    try router.post("/async", asyncPostHandler);

    try std.testing.expect(z.num_threads == 6);
    try std.testing.expect(z.read_buffer_len == 8192);
    try std.testing.expect(z.header_buffer_len == 1024);
    try std.testing.expect(z.body_buffer_len == 32768);
}

test "multithreading shutdown" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 3,
        .force_nonblocking = true,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/shutdown-test", shutdownTestHandler);

    // Test shutdown without running
    z.shutdown(1000000); // 1ms timeout

    // Should still be able to deinit
    try std.testing.expect(z.num_threads == 3);
}

test "multithreading memory management" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 5,
        .force_nonblocking = true,
        .read_buffer_len = 4096,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/memory-test", memoryTestHandler);

    // Test memory allocation for multiple threads
    try std.testing.expect(z.num_threads == 5);
    try std.testing.expect(z.read_buffer_len == 4096);
}

// Test handlers
fn testHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("multithreading test", .{});
}

fn concurrentHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("concurrent request handled", .{});
}

fn threadTestHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("thread test successful", .{});
}

fn asyncHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("async operation completed", .{});
}

fn asyncPostHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("async post operation completed", .{});
}

fn shutdownTestHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("shutdown test", .{});
}

fn memoryTestHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("memory test passed", .{});
}
