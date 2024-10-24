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

test "Zinc with std.heap.GeneralPurposeAllocator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = true,
    }){};
    const allocator = gpa.allocator();

    var z = try zinc.init(.{
        .allocator = allocator,
        .num_threads = 255,
    });
    defer z.deinit();

    z.shutdown(0);
}

// test "Zinc with std.testing.allocator" {
//     const allocator = std.testing.allocator;
//     var z = try zinc.init(.{
//         .allocator = allocator,
//         .num_threads = 100,
//     });
//     defer z.deinit();

//     z.shutdown(0);
// }

test "Zinc with std.heap.ArenaAllocator" {
    const page_allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(page_allocator);
    const allocator = arena.allocator();

    var z = try zinc.init(.{
        .allocator = allocator,
        .num_threads = 255,
    });
    defer z.deinit();
    z.shutdown(0);
}

test "Zinc with LoggingAllocator" {
    var allocator = std.heap.LoggingAllocator(.info, .debug).init(std.heap.page_allocator);
    var z = try zinc.init(.{
        .allocator = allocator.allocator(),
        .num_threads = 255,
    });
    defer z.deinit();
    z.shutdown(0);
}

test "Zinc with std.heap.page_allocator" {
    const allocator = std.heap.page_allocator;
    var z = try zinc.init(.{
        .allocator = allocator,
        .num_threads = 255,
    });
    defer z.deinit();
    z.shutdown(0);
}

test "Zinc Server" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = true,
        .thread_safe = true,
        .safety = true,
    }){};
    const allocator = gpa.allocator();

    var z = try zinc.init(.{ .num_threads = 255, .allocator = allocator });
    defer z.deinit();

    defer z.shutdown(0);

    var router = z.getRouter();
    try router.get("/test", testHandle);
    const routes = router.getRoutes();
    defer routes.deinit();

    try std.testing.expectEqual(1, routes.items.len);
    try std.testing.expectEqual(1, routes.items[0].handlers.items.len);

    // Create an HTTP client.
    var client = std.http.Client{ .allocator = z.allocator };
    defer client.deinit();

    const url = try std.fmt.allocPrint(z.allocator, "http://127.0.0.1:{any}/test", .{z.getPort()});
    defer z.allocator.free(url);
    var req = try fetch(&client, .{ .method = .GET, .location = .{ .url = url } });
    defer req.deinit();

    const body_buffer = req.reader().readAllAlloc(z.allocator, req.response.content_length.?) catch unreachable;
    try std.testing.expectEqualStrings("Hello World!", body_buffer);

    // test use middleware
    try router.use(&.{zinc.Middleware.cors()});
    try std.testing.expectEqual(1, router.getRoutes().items.len);
    try std.testing.expectEqual(2, router.getRoutes().items[0].handlers.items.len);

    // Add OPTIONS method to the route
    try router.options("/test", testHandle);
    // Create an HTTP client.
    var req2 = try fetch(&client, .{ .method = .OPTIONS, .location = .{ .url = url } });
    defer req2.deinit();

    var header_buffer: []u8 = undefined;
    header_buffer = try z.allocator.alloc(u8, 1024);
    header_buffer = req2.response.parser.get();

    // HTTP/1.1 204 No Content
    // connection: close
    // content-length: 0
    // Access-Control-Allow-Origin: *
    // Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS
    // Access-Control-Allow-Headers: Content-Type
    // Access-Control-Allow-Private-Network: true
    var it = std.http.HeaderIterator.init(header_buffer);
    try std.testing.expect(!it.is_trailer);

    // {
    //     const header = it.next().?;
    //     try std.testing.expect(!it.is_trailer);
    //     try std.testing.expectEqualStrings("connection", header.name);
    //     try std.testing.expectEqualStrings("close", header.value);
    // }

    {
        const header = it.next().?;
        try std.testing.expect(!it.is_trailer);
        try std.testing.expectEqualStrings("content-length", header.name);
        try std.testing.expectEqualStrings("0", header.value);
    }

    {
        const header = it.next().?;
        try std.testing.expect(!it.is_trailer);
        try std.testing.expectEqualStrings("Access-Control-Allow-Origin", header.name);
        try std.testing.expectEqualStrings("*", header.value);
    }

    {
        const header = it.next().?;
        try std.testing.expect(!it.is_trailer);
        try std.testing.expectEqualStrings("Access-Control-Allow-Methods", header.name);
        try std.testing.expectEqualStrings("GET, POST, PUT, DELETE, OPTIONS", header.value);
    }

    // Test Middleware
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

    const mid_url = try std.fmt.allocPrint(z.allocator, "http://127.0.0.1:{any}/mid", .{z.getPort()});
    defer z.allocator.free(mid_url);

    var req3 = try fetch(&client, .{ .method = .GET, .location = .{ .url = mid_url } });
    defer req3.deinit();

    const req3_body_buffer = req3.reader().readAllAlloc(z.allocator, req3.response.content_length.?) catch unreachable;
    try std.testing.expectEqualStrings("Hello Zinc!", req3_body_buffer);
}

fn testHandle(ctx: *Context) anyerror!void {
    try ctx.text("Hello World!", .{});
}

/// see  std.http.Client.fetch
fn fetch(client: *std.http.Client, options: std.http.Client.FetchOptions) !std.http.Client.Request {
    const uri = switch (options.location) {
        .url => |u| try std.Uri.parse(u),
        .uri => |u| u,
    };
    // var server_header_buffer = options.server_header_buffer orelse (16 * 1024);
    var server_header_buffer: [1024]u8 = undefined;

    const method: std.http.Method = options.method orelse
        if (options.payload != null) .POST else .GET;

    var req = try std.http.Client.open(client, method, uri, .{
        .server_header_buffer = options.server_header_buffer orelse &server_header_buffer,
        .redirect_behavior = options.redirect_behavior orelse
            if (options.payload == null) @enumFromInt(3) else .unhandled,
        .headers = options.headers,
        .extra_headers = options.extra_headers,
        .privileged_headers = options.privileged_headers,
        // .keep_alive = options.keep_alive,
        .keep_alive = false,
    });

    if (options.payload) |payload| req.transfer_encoding = .{ .content_length = payload.len };

    try req.send();

    if (options.payload) |payload| try req.writeAll(payload);

    try req.finish();
    try req.wait();
    return req;
}
