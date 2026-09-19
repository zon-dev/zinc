//! Engine configuration, allocators, and the README-style usage examples.
//!
//! Examples that used to only register routes now run them in-process through
//! `harness.App`, so a broken handler fails the test. Socket-level smoke
//! coverage stays in "Engine: accepts a connection".

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const compat = @import("../zinc/posix_compat.zig");
const Context = zinc.Context;
const harness = @import("harness.zig");

test "Engine: init with custom configuration" {
    var engine = try zinc.Engine.init(.{
        .addr = "127.0.0.1",
        .port = 0,
        .allocator = testing.allocator,
        .num_threads = 2,
        .read_buffer_len = 8192,
        .header_buffer_len = 2048,
        .body_buffer_len = 16384,
        .stack_size = 1048576,
    });
    defer engine.deinit();

    try testing.expect(engine.getPort() > 0);
    try testing.expectEqual(@as(usize, 2), engine.num_threads);
    try testing.expectEqual(@as(usize, 8192), engine.read_buffer_len);
    try testing.expectEqual(@as(usize, 2048), engine.header_buffer_len);
    try testing.expectEqual(@as(usize, 16384), engine.body_buffer_len);
}

test "Engine: default configuration" {
    var engine = try zinc.Engine.default();
    defer engine.deinit();
    try testing.expect(engine.getPort() > 0);
    try testing.expectEqual(@as(usize, 32), engine.num_threads);
    try testing.expectEqual(@as(usize, 32768), engine.read_buffer_len);
}

test "Engine: init via zinc.init" {
    var engine = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 4,
        .read_buffer_len = 8192,
    });
    defer engine.deinit();
    try testing.expectEqual(@as(usize, 4), engine.num_threads);
    try testing.expectEqual(@as(usize, 8192), engine.read_buffer_len);
}

test "Engine: works with testing, Debug and Arena allocators" {
    try withAllocator(testing.allocator);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    try withAllocator(gpa.allocator());

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try withAllocator(arena.allocator());
}

fn withAllocator(allocator: std.mem.Allocator) !void {
    var z = try zinc.init(.{
        .allocator = allocator,
        .addr = "127.0.0.1",
        .port = 0,
        .num_threads = 1,
    });
    defer z.deinit();
    try testing.expect(z.getPort() > 0);
    try testing.expectEqual(@as(usize, 1), z.num_threads);

    var router = z.getRouter();
    try router.get("/test", harness.text("Hello World!"));
    try testing.expectEqual(@as(usize, 1), harness.routeCount(router));
}

test "Engine: shutdown without running" {
    var engine = try zinc.Engine.init(.{ .port = 0, .num_threads = 1 });
    engine.shutdown(1_000_000);
    engine.deinit();
}

test "Engine: accepts a connection" {
    var z = try zinc.init(.{
        .allocator = testing.allocator,
        .addr = "127.0.0.1",
        .port = 0,
        .num_threads = 1,
    });
    defer z.deinit();
    try z.getRouter().get("/test", harness.text("Hello World!"));

    const server_thread = try std.Thread.spawn(.{}, zinc.Engine.run, .{z});
    defer {
        z.shutdown(0);
        server_thread.join();
    }

    const port = z.getPort();
    var sa: std.posix.sockaddr.in = undefined;
    sa.family = std.posix.AF.INET;
    sa.port = std.mem.nativeToBig(u16, port);
    sa.addr = std.mem.nativeToBig(u32, 0x7f000001);

    var connected = false;
    for (0..10) |_| {
        const sockfd = try compat.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
        defer compat.close(sockfd);
        const sockaddr: *const std.posix.sockaddr = @ptrCast(&sa);
        compat.connect(sockfd, sockaddr, @sizeOf(std.posix.sockaddr.in)) catch |err| {
            if (err == error.ConnectionRefused) continue;
            return err;
        };
        connected = true;
        break;
    }
    try testing.expect(connected);
}

test "Engine: router middleware and OPTIONS register independently of the server" {
    var z = try zinc.init(.{
        .allocator = testing.allocator,
        .addr = "127.0.0.1",
        .port = 0,
        .num_threads = 1,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/test", harness.text("Hello World!"));
    try router.use(&.{zinc.Middleware.cors()});
    try testing.expectEqual(@as(usize, 2), (try router.getRoute(.GET, "/test")).handlers.items.len);

    try router.options("/test", harness.text("Hello World!"));
    try testing.expectEqual(@as(usize, 2), harness.routeCount(router));

    const mid1 = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.text("Hello ", .{});
            try ctx.next();
        }
    }.middle;
    const mid2 = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.next();
            try ctx.text("!", .{});
        }
    }.middle;
    try router.use(&.{ mid1, mid2 });
    try router.get("/mid", harness.text("Zinc"));
    try testing.expectEqual(@as(usize, 3), harness.routeCount(router));
}

test "Engine: high-performance buffer configuration" {
    var z = try zinc.init(.{
        .port = 0,
        .addr = "127.0.0.1",
        .num_threads = 8,
        .read_buffer_len = 32768,
        .header_buffer_len = 4096,
        .body_buffer_len = 65536,
        .stack_size = 4194304,
    });
    defer z.deinit();
    try testing.expectEqual(@as(usize, 8), z.num_threads);
    try testing.expectEqual(@as(usize, 32768), z.read_buffer_len);
    try testing.expectEqual(@as(usize, 4096), z.header_buffer_len);
    try testing.expectEqual(@as(usize, 65536), z.body_buffer_len);
}

// ---------------------------------------------------------------------------
// Usage examples — handlers actually run
// ---------------------------------------------------------------------------

test "example: JSON API" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    try app.router.get("/api/user", struct {
        fn handler(ctx: *Context) anyerror!void {
            try ctx.json(.{ .id = @as(i32, 1), .name = "John Doe", .email = "john@example.com", .active = true }, .{});
        }
    }.handler);
    try app.router.post("/api/user", struct {
        fn handler(ctx: *Context) anyerror!void {
            try ctx.json(.{ .message = "User created", .data = ctx.getBody() }, .{});
        }
    }.handler);

    {
        var res = try app.get("/api/user");
        defer res.deinit();
        try res.expectHeader("Content-Type", "application/json");
        try res.expectBodyContains("John Doe");
        try res.expectBodyContains("john@example.com");
    }
    {
        var body = "name=zinc".*;
        var res = try app.post("/api/user", &body);
        defer res.deinit();
        try res.expectBodyContains("User created");
    }
}

test "example: query parameters" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/search", struct {
        fn handler(ctx: *Context) anyerror!void {
            try ctx.json(.{
                .query = ctx.getQuery("q") orelse "",
                .page = ctx.getQuery("page") orelse "1",
                .results = &.{},
            }, .{});
        }
    }.handler);

    var res = try app.get("/search?q=zinc&page=2");
    defer res.deinit();
    try res.expectBodyContains("zinc");
    try res.expectBodyContains("2");
}

test "example: path-parameter handlers (storage contract)" {
    // Route-driven param binding is not implemented yet: `getRoute` uses exact
    // `find`, so `/user/:id` is stored as a parameter node and cannot be
    // looked up by that literal. The example still registers the routes and
    // the handler reads `getParam` once the map is populated.
    const user = struct {
        fn handler(ctx: *Context) anyerror!void {
            try ctx.json(.{ .id = ctx.getParam("id").?.value, .message = "User details" }, .{});
        }
    }.handler;
    const post = struct {
        fn handler(ctx: *Context) anyerror!void {
            try ctx.json(.{
                .userId = ctx.getParam("id").?.value,
                .postId = ctx.getParam("postId").?.value,
                .message = "Post details",
            }, .{});
        }
    }.handler;

    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/user/:id", user);
    try app.router.get("/user/:id/posts/:postId", post);
    try testing.expectEqual(@as(usize, 2), harness.routeCount(app.router));

    var tc = try harness.newContext(testing.allocator, .{ .target = "/user/42" });
    defer tc.deinit();
    try tc.ctx.params.put("id", .{ .name = "id", .value = "42" });
    try user(tc.ctx);
    try harness.expectBodyContains(tc.ctx, "42");
    try harness.expectBodyContains(tc.ctx, "User details");
}

test "example: static files on the engine" {
    var engine = try zinc.Engine.init(.{ .port = 0, .num_threads = 2, .allocator = testing.allocator });
    defer engine.deinit();
    try engine.static("/static", harness.assets.dir);
    try engine.StaticFile("/style.css", harness.assets.style_css);
    try testing.expect(engine.getPort() > 0);
    try testing.expect(engine.getRouter().static_files.?.contains("/style.css"));
}

test "example: redirect sets Location" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();
    tc.ctx.redirect(.moved_permanently, "/new-page") catch {};
    try harness.expectHeader(tc.ctx, "Location", "/new-page");

    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/new-page", harness.text("This is the new page!"));
    var res = try app.get("/new-page");
    defer res.deinit();
    try res.expectBody("This is the new page!");
}

test "example: CORS middleware" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.use(&.{
        struct {
            fn handler(ctx: *Context) anyerror!void {
                try ctx.setHeader("Access-Control-Allow-Origin", "*");
                try ctx.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
                try ctx.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
                if (ctx.getMethod() == .OPTIONS) {
                    try ctx.status(.no_content);
                    return;
                }
                try ctx.next();
            }
        }.handler,
    });
    try app.router.get("/api/data", struct {
        fn handler(ctx: *Context) anyerror!void {
            try ctx.json(.{ .message = "CORS enabled API", .data = &.{ @as(i32, 1), 2, 3, 4, 5 } }, .{});
        }
    }.handler);

    {
        var res = try app.get("/api/data");
        defer res.deinit();
        try res.expectHeader("Access-Control-Allow-Origin", "*");
        try res.expectBodyContains("CORS enabled API");
    }
    {
        var res = try app.dispatch(.{ .method = .OPTIONS, .target = "/api/data" });
        defer res.deinit();
        try res.expectStatus(.no_content);
        try res.expectHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    }
}

test "example: JSON and text benchmark handlers" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/bench", harness.text("Hello, World!"));
    try app.router.get("/bench/json", struct {
        fn handler(ctx: *Context) anyerror!void {
            const io = std.Io.Threaded.global_single_threaded.io();
            const ts = std.Io.Clock.now(.real, io);
            const timestamp_ms = @divTrunc(@as(i128, ts.nanoseconds), std.time.ns_per_ms);
            try ctx.json(.{
                .message = "Hello, World!",
                .timestamp = @as(i64, @intCast(timestamp_ms)),
            }, .{});
        }
    }.handler);

    {
        var res = try app.get("/bench");
        defer res.deinit();
        try res.expectBody("Hello, World!");
    }
    {
        var res = try app.get("/bench/json");
        defer res.deinit();
        try res.expectBodyContains("Hello, World!");
        try res.expectBodyContains("timestamp");
    }
}
