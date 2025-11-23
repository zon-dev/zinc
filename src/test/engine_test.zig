const std = @import("std");
const testing = std.testing;
const http = std.http;

const zinc = @import("../zinc.zig");
const Request = zinc.Request;
const Response = zinc.Response;
const Context = zinc.Context;

const Route = zinc.Route;
const Router = zinc.Router;
const RouteError = Route.RouteError;

fn startServer(z: *zinc.Engine) !std.Thread {
    return try std.Thread.spawn(.{}, zinc.Engine.run, .{z});
}

test "Zinc with std.heap.GeneralPurposeAllocator" {
    const allocator = std.testing.allocator;

    var z = try zinc.init(.{
        .allocator = allocator,
        .addr = "127.0.0.1",
        .port = 0,
        .num_threads = 1,
        .force_nonblocking = true,
    });
    defer z.deinit();

    try std.testing.expect(z.getPort() > 0);
    try std.testing.expect(z.num_threads == 1);
}

test "Zinc with std.testing.allocator" {
    var z = try zinc.init(.{
        .allocator = std.testing.allocator,
        .addr = "127.0.0.1",
        .port = 0,
        .num_threads = 1,
        .force_nonblocking = true,
    });
    defer z.deinit();

    try std.testing.expect(z.getPort() > 0);
    try std.testing.expect(z.num_threads == 1);
}

test "Zinc with std.heap.ArenaAllocator" {
    const page_allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    const allocator = arena.allocator();

    var z = try zinc.init(.{
        .allocator = allocator,
        .num_threads = 255,
    });
    defer z.deinit();

    const server_thread = try startServer(z);
    // Give server time to start - use posix.nanosleep
    std.posix.nanosleep(0, 10 * std.time.ns_per_ms);
    // Shutdown server first
    z.shutdown(0);
    // Give server time to stop
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
    // Then join thread
    server_thread.join();
}

test "Zinc with std.heap.page_allocator" {
    const allocator = std.heap.page_allocator;
    var z = try zinc.init(.{
        .allocator = allocator,
        .num_threads = 255,
    });
    defer z.deinit();

    const server_thread = try startServer(z);
    // Give server time to start - use posix.nanosleep
    std.posix.nanosleep(0, 10 * std.time.ns_per_ms);
    // Shutdown server first
    z.shutdown(0);
    // Give server time to stop
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
    // Then join thread
    server_thread.join();
}

test "Zinc Server" {
    var z = try zinc.init(.{
        .allocator = std.testing.allocator,
        .addr = "127.0.0.1",
        .port = 0,
        .num_threads = 1,
        .force_nonblocking = true,
    });
    defer z.deinit();

    try std.testing.expect(z.getPort() > 0);
    try std.testing.expect(z.num_threads == 1);

    // Test router functionality without running server
    var router = z.getRouter();
    try router.get("/test", testHandle);
    const routes = router.getRoutes();
    defer routes.deinit();

    try std.testing.expectEqual(1, routes.items.len);
    try std.testing.expectEqual(1, routes.items[0].handlers.items.len);

    // Test middleware without running server
    try router.use(&.{zinc.Middleware.cors()});
    const routes2 = router.getRoutes();
    defer routes2.deinit();
    try std.testing.expectEqual(1, routes2.items.len);
    try std.testing.expectEqual(2, routes2.items[0].handlers.items.len);

    // Add OPTIONS method to the route
    try router.options("/test", testHandle);
    const routes3 = router.getRoutes();
    defer routes3.deinit();
    // OPTIONS method is added to the existing route, not creating a new one
    try std.testing.expectEqual(1, routes3.items.len);

    // Test additional middleware without running server
    const mid1 = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Hello ", .{});
            try ctx.next();
        }
    }.middle;

    const mid2 = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.next();
            try ctx.text("!", .{});
        }
    }.middle;

    const handle = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Zinc", .{});
        }
    }.anyHandle;

    try router.use(&.{ mid1, mid2 });
    try router.get("/mid", handle);
    const routes4 = router.getRoutes();
    defer routes4.deinit();
    try std.testing.expectEqual(2, routes4.items.len); // /test and /mid
}

fn testHandle(ctx: *Context) anyerror!void {
    try ctx.text("Hello World!", .{});
}
