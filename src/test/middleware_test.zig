//! Middleware chain and the built-in `zinc.Middleware`.
//!
//! A middleware may act before and after `ctx.next()`, and stops the chain by
//! not calling it. `Router.use` prepends middleware so the handler runs last.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Context = zinc.Context;
const harness = @import("harness.zig");

test "Middleware: a before/after pair wraps the handler" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

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

    try app.router.use(&.{ mid1, mid2 });
    try app.router.get("/test", harness.text("world"));

    try testing.expectEqual(@as(usize, 1), harness.routeCount(app.router));
    try testing.expectEqual(@as(usize, 3), (try app.router.getRoute(.GET, "/test")).handlers.items.len);

    var res = try app.get("/test");
    defer res.deinit();
    try res.expectStatus(.ok);
    try res.expectBody("Hello world!");
}

test "Middleware: chain order, short-circuit, headers and status" {
    const set_header = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.setHeader("X-Middleware", "applied");
            try ctx.next();
        }
    }.middle;
    const block = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.text("Blocked", .{ .status = .forbidden });
        }
    }.middle;
    const n1 = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.text("1", .{});
            try ctx.next();
        }
    }.middle;
    const n2 = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.text("2", .{});
            try ctx.next();
        }
    }.middle;
    const n3 = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.text("3", .{});
            try ctx.next();
        }
    }.middle;
    const accepted = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.next();
            try ctx.setStatus(.accepted);
        }
    }.middle;
    const many_headers = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.setHeader("X-First", "1");
            try ctx.setHeader("X-Second", "2");
            try ctx.setHeader("X-Third", "3");
            try ctx.next();
        }
    }.middle;
    const outer = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.setHeader("X-Outer", "in");
            try ctx.text("[", .{});
            try ctx.next();
            try ctx.text("]", .{});
        }
    }.middle;
    const inner = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.text("(", .{});
            try ctx.next();
            try ctx.text(")", .{});
        }
    }.middle;

    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        try app.router.use(&.{set_header});
        try app.router.get("/test", harness.text("OK"));
        var res = try app.get("/test");
        defer res.deinit();
        try res.expectHeader("X-Middleware", "applied");
        try res.expectBody("OK");
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        try app.router.use(&.{block});
        try app.router.get("/test", harness.text("Should not reach here"));
        var res = try app.get("/test");
        defer res.deinit();
        try res.expectStatus(.forbidden);
        try res.expectBody("Blocked");
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        try app.router.use(&.{ n1, n2, n3 });
        try app.router.get("/test", harness.text("H"));
        var res = try app.get("/test");
        defer res.deinit();
        try res.expectBody("123H");
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        harness.Trace.reset();
        try app.router.use(&.{ harness.tracingMiddleware("a"), harness.tracingMiddleware("b") });
        try app.router.get("/test", harness.tracingHandler("handler", "done"));
        var res = try app.get("/test");
        defer res.deinit();
        try harness.Trace.expectOrder(&.{ "a:before", "b:before", "handler", "b:after", "a:after" });
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        try app.router.use(&.{accepted});
        try app.router.get("/test", harness.text("body"));
        var res = try app.get("/test");
        defer res.deinit();
        try res.expectStatus(.accepted);
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        try app.router.use(&.{many_headers});
        try app.router.get("/test", harness.text("OK"));
        var res = try app.get("/test");
        defer res.deinit();
        try res.expectHeader("X-First", "1");
        try res.expectHeader("X-Second", "2");
        try res.expectHeader("X-Third", "3");
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        try app.router.use(&.{ outer, inner });
        try app.router.get("/test", harness.text("core"));
        var res = try app.get("/test");
        defer res.deinit();
        try res.expectBody("[(core)]");
        try res.expectHeader("X-Outer", "in");
    }
}

test "Middleware: a route with no middleware runs just its handler" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/test", harness.text("bare"));
    try testing.expectEqual(@as(usize, 1), (try app.router.getRoute(.GET, "/test")).handlers.items.len);
    var res = try app.get("/test");
    defer res.deinit();
    try res.expectBody("bare");
}

test "Middleware: several routes share the same middleware" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    const mid = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.setHeader("X-Middleware-Applied", "yes");
            try ctx.next();
        }
    }.middle;
    try app.router.use(&.{mid});
    try app.router.get("/route1", harness.text("route1"));
    try app.router.get("/route2", harness.text("route2"));

    inline for ([_]struct { path: []const u8, body: []const u8 }{
        .{ .path = "/route1", .body = "route1" },
        .{ .path = "/route2", .body = "route2" },
    }) |c| {
        var res = try app.get(c.path);
        defer res.deinit();
        try res.expectBody(c.body);
        try res.expectHeader("X-Middleware-Applied", "yes");
    }
}

test "Middleware: errors abort the chain and skip after-hooks" {
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        harness.Trace.reset();
        try app.router.use(&.{harness.failingHandler(error.MiddlewareRejected)});
        try app.router.get("/test", harness.tracingHandler("handler", "never"));
        try testing.expectError(error.MiddlewareRejected, app.get("/test"));
        try harness.Trace.expectOrder(&.{});
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        harness.Trace.reset();
        try app.router.use(&.{harness.tracingMiddleware("mw")});
        try app.router.get("/test", harness.failingHandler(error.HandlerFailed));
        try testing.expectError(error.HandlerFailed, app.get("/test"));
        try harness.Trace.expectOrder(&.{"mw:before"});
    }
}

test "Middleware.cors: origin, preflight and composition" {
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        try app.router.use(&.{zinc.Middleware.cors()});
        try app.router.get("/test", harness.text("body"));
        var res = try app.get("/test");
        defer res.deinit();
        try res.expectHeader("Access-Control-Allow-Origin", "*");
        try res.expectBody("body");
        try res.expectNoHeader("Access-Control-Allow-Methods");
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        try app.router.use(&.{zinc.Middleware.cors()});
        try app.router.get("/test", harness.text("body"));
        var res = try app.dispatch(.{
            .method = .GET,
            .target = "/test",
            .req_headers = &.{.{ .name = "Origin", .value = "https://example.com" }},
        });
        defer res.deinit();
        try res.expectHeader("Access-Control-Allow-Origin", "https://example.com");
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        harness.Trace.reset();
        try app.router.use(&.{zinc.Middleware.cors()});
        try app.router.get("/test", harness.tracingHandler("handler", "should not run"));
        var res = try app.dispatch(.{ .method = .OPTIONS, .target = "/test" });
        defer res.deinit();
        try res.expectStatus(.no_content);
        try res.expectHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        try res.expectHeader("Access-Control-Allow-Headers", "Content-Type");
        try res.expectHeader("Access-Control-Allow-Private-Network", "true");
        try harness.Trace.expectOrder(&.{});
        try res.expectNoBody();
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        harness.Trace.reset();
        try app.router.use(&.{zinc.Middleware.cors()});
        try app.router.get("/test", harness.tracingHandler("handler", "reached"));
        var res = try app.get("/test");
        defer res.deinit();
        try harness.Trace.expectOrder(&.{"handler"});
        try res.expectBody("reached");
    }
    {
        var app = try harness.App.init(testing.allocator);
        defer app.deinit();
        const tagger = struct {
            fn middle(ctx: *Context) anyerror!void {
                try ctx.setHeader("X-Tagged", "1");
                try ctx.next();
            }
        }.middle;
        try app.router.use(&.{ zinc.Middleware.cors(), tagger });
        try app.router.get("/test", harness.text("body"));
        var res = try app.get("/test");
        defer res.deinit();
        try res.expectHeader("Access-Control-Allow-Origin", "*");
        try res.expectHeader("X-Tagged", "1");
        try res.expectBody("body");
    }
}
