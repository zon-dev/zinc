const std = @import("std");
const zinc = @import("../zinc.zig");

test "aio json example" {
    var engine = try zinc.Engine.init(.{
        .port = 0,
        .force_nonblocking = true,
        .num_threads = 2,
    });
    defer engine.deinit();

    var router = engine.getRouter();

    try router.get("/api/user", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            try ctx.json(.{
                .id = 1,
                .name = "John Doe",
                .email = "john@example.com",
                .active = true,
            }, .{});
        }
    }.handler);

    try router.post("/api/user", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            const body = ctx.getBody();
            try ctx.json(.{
                .message = "User created",
                .data = body,
            }, .{});
        }
    }.handler);

    try std.testing.expect(engine.getPort() > 0);
}

test "aio query parameters example" {
    var engine = try zinc.Engine.init(.{
        .port = 0,
        .force_nonblocking = true,
        .num_threads = 2,
    });
    defer engine.deinit();

    var router = engine.getRouter();

    try router.get("/search", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            const query = ctx.getQuery("q") orelse "";
            const page = ctx.getQuery("page") orelse "1";

            try ctx.json(.{
                .query = query,
                .page = page,
                .results = &.{},
            }, .{});
        }
    }.handler);

    try std.testing.expect(engine.getPort() > 0);
}

test "aio path parameters example" {
    var engine = try zinc.Engine.init(.{
        .port = 0,
        .force_nonblocking = true,
        .num_threads = 2,
    });
    defer engine.deinit();

    var router = engine.getRouter();

    try router.get("/user/:id", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            const id = ctx.getParam("id").?.value;
            try ctx.json(.{
                .id = id,
                .message = "User details",
            }, .{});
        }
    }.handler);

    try router.get("/user/:id/posts/:postId", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            const userId = ctx.getParam("id").?.value;
            const postId = ctx.getParam("postId").?.value;

            try ctx.json(.{
                .userId = userId,
                .postId = postId,
                .message = "Post details",
            }, .{});
        }
    }.handler);

    try std.testing.expect(engine.getPort() > 0);
}

test "aio static files example" {
    var engine = try zinc.Engine.init(.{
        .port = 0,
        .force_nonblocking = true,
        .num_threads = 2,
    });
    defer engine.deinit();

    // Add static file serving
    try engine.static("/static", "src/test/assets");

    // Add static file route
    try engine.StaticFile("/favicon.ico", "src/test/assets/favicon.ico");

    try std.testing.expect(engine.getPort() > 0);
}

test "aio redirects example" {
    var engine = try zinc.Engine.init(.{
        .port = 0,
        .force_nonblocking = true,
        .num_threads = 2,
    });
    defer engine.deinit();

    var router = engine.getRouter();

    try router.get("/old-page", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            try ctx.redirect(.moved_permanently, "/new-page");
        }
    }.handler);

    try router.get("/new-page", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            try ctx.text("This is the new page!", .{});
        }
    }.handler);

    try std.testing.expect(engine.getPort() > 0);
}

test "aio cors example" {
    var engine = try zinc.Engine.init(.{
        .port = 0,
        .force_nonblocking = true,
        .num_threads = 2,
    });
    defer engine.deinit();

    // Add CORS middleware
    try engine.use(&.{
        struct {
            fn handler(ctx: *zinc.Context) anyerror!void {
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

    var router = engine.getRouter();

    try router.get("/api/data", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            try ctx.json(.{
                .message = "CORS enabled API",
                .data = &.{ 1, 2, 3, 4, 5 },
            }, .{});
        }
    }.handler);

    try std.testing.expect(engine.getPort() > 0);
}

test "aio multithreading example" {
    var engine = try zinc.Engine.init(.{
        .port = 0,
        .force_nonblocking = true,
        .num_threads = 8, // Multiple threads
    });
    defer engine.deinit();

    var router = engine.getRouter();

    try router.get("/thread-info", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            const thread_id = std.Thread.getCurrentId();
            try ctx.json(.{
                .thread_id = @as(u64, @intCast(thread_id)),
                .message = "Handled by thread",
            }, .{});
        }
    }.handler);

    try std.testing.expect(engine.getPort() > 0);
    try std.testing.expect(engine.num_threads == 8);
}

test "aio benchmark example" {
    var engine = try zinc.Engine.init(.{
        .port = 0,
        .force_nonblocking = true,
        .num_threads = 4,
        .read_buffer_len = 16384, // Larger buffer for performance
        .header_buffer_len = 4096,
        .body_buffer_len = 32768,
    });
    defer engine.deinit();

    var router = engine.getRouter();

    // Simple response for benchmarking
    try router.get("/bench", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Hello, World!", .{});
        }
    }.handler);

    // JSON response for benchmarking
    try router.get("/bench/json", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            // Get current time in milliseconds using posix.clock_gettime
            const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
                // Fallback to 0 if clock_gettime fails
                try ctx.json(.{
                    .message = "Hello, World!",
                    .timestamp = 0,
                }, .{});
                return;
            };
            // timespec structure has sec and nsec fields on macOS
            const sec = @as(i128, @intCast(ts.sec));
            const nsec = @as(i128, @intCast(ts.nsec));
            const timestamp_ms = @divTrunc(sec * std.time.ns_per_s + nsec, std.time.ns_per_ms);
            try ctx.json(.{
                .message = "Hello, World!",
                .timestamp = @as(i64, @intCast(timestamp_ms)),
            }, .{});
        }
    }.handler);

    try std.testing.expect(engine.getPort() > 0);
}
