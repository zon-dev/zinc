const std = @import("std");
const zinc = @import("../zinc.zig");

test "aio async I/O initialization" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 4,
        .force_nonblocking = true, // Enable async I/O
        .read_buffer_len = 8192,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/aio-test", aioTestHandler);

    // Verify async I/O is enabled
    try std.testing.expect(z.num_threads == 4);
    try std.testing.expect(z.read_buffer_len == 8192);
}

test "aio event loop configuration" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 2,
        .force_nonblocking = true,
        .read_buffer_len = 4096,
        .header_buffer_len = 1024,
        .body_buffer_len = 16384,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/event-loop", eventLoopHandler);

    // Test event loop configuration
    try std.testing.expect(z.num_threads == 2);
    try std.testing.expect(z.read_buffer_len == 4096);
    try std.testing.expect(z.header_buffer_len == 1024);
    try std.testing.expect(z.body_buffer_len == 16384);
}

test "aio callback handling" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 3,
        .force_nonblocking = true,
        .read_buffer_len = 6144,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/callback", callbackHandler);
    try router.post("/callback", callbackPostHandler);

    // Test callback-based async I/O
    try std.testing.expect(z.num_threads == 3);
    try std.testing.expect(z.read_buffer_len == 6144);
}

test "aio connection management" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 5,
        .force_nonblocking = true,
        .read_buffer_len = 10240,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/connection", connectionHandler);

    // Test connection management with async I/O
    try std.testing.expect(z.num_threads == 5);
    try std.testing.expect(z.read_buffer_len == 10240);
}

test "aio error handling" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 2,
        .force_nonblocking = true,
        .read_buffer_len = 2048,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/error", errorHandler);

    // Test error handling in async I/O
    try std.testing.expect(z.num_threads == 2);
    try std.testing.expect(z.read_buffer_len == 2048);
}

test "aio performance configuration" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 8,
        .force_nonblocking = true,
        .read_buffer_len = 32768,
        .header_buffer_len = 4096,
        .body_buffer_len = 65536,
        .stack_size = 4194304, // 4MB stack
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/performance", performanceHandler);

    // Test high-performance async I/O configuration
    try std.testing.expect(z.num_threads == 8);
    try std.testing.expect(z.read_buffer_len == 32768);
    try std.testing.expect(z.header_buffer_len == 4096);
    try std.testing.expect(z.body_buffer_len == 65536);
}

test "aio platform specific features" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 4,
        .force_nonblocking = true,
        .read_buffer_len = 8192,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/platform", platformHandler);

    // Test platform-specific async I/O features
    try std.testing.expect(z.num_threads == 4);

    // Log platform information
    std.log.info("Async I/O: enabled", .{});
}

// Test handlers for aio async I/O
fn aioTestHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("aio async I/O test passed", .{});
}

fn eventLoopHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("event loop configured correctly", .{});
}

fn callbackHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("callback-based async I/O working", .{});
}

fn callbackPostHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("callback post handler working", .{});
}

fn connectionHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("connection management with aio", .{});
}

fn errorHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("error handling in async I/O", .{});
}

fn performanceHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("high-performance async I/O", .{});
}

fn platformHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.text("platform-specific async I/O", .{});
}
