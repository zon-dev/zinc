//! Tests for the middleware chain and the built-in `zinc.Middleware`.
//!
//! The contract: a middleware receives the context, may act before and after
//! calling `ctx.next()`, and stops the chain by simply not calling it.
//! Middleware registered with `Router.use` is prepended to every route's
//! handler list, so the handler always runs last.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Context = zinc.Context;
const Router = zinc.Router;

const harness = @import("harness.zig");

fn newRouter() !*Router {
    return Router.init(.{ .allocator = testing.allocator });
}

/// Register `handlers` as middleware plus `handler` on GET /test, then run the
/// resulting chain against a fresh context and hand it back to the caller.
fn runTest(
    router: *Router,
    middlewares: []const zinc.HandlerFn,
    handler: zinc.HandlerFn,
) !harness.TestContext {
    try router.use(middlewares);
    try router.get("/test", handler);

    var tc = try harness.newContext(testing.allocator, .{ .method = .GET, .target = "/test" });
    errdefer tc.deinit();

    const route = try router.getRoute(.GET, "/test");
    try harness.runChain(tc.ctx, route);
    return tc;
}

test "Middleware: a before/after pair wraps the handler" {
    var router = try newRouter();
    defer router.deinit();

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
    try router.get("/test", harness.textHandler("world"));

    const routes = router.getRoutes();
    defer routes.deinit();
    try testing.expectEqual(@as(usize, 1), routes.items.len);
    try testing.expectEqual(@as(usize, 3), routes.items[0].handlers.items.len);

    var tc = try harness.newContext(testing.allocator, .{ .method = .GET, .target = "/test" });
    defer tc.deinit();

    const route = try router.getRoute(.GET, "/test");
    try harness.runChain(tc.ctx, route);

    try harness.expectStatus(tc.ctx, .ok);
    try testing.expectEqual(@as(usize, 3), tc.ctx.handlers.items.len);
    try harness.expectBody(tc.ctx, "Hello world!");
}

test "Middleware: a single middleware can set a header" {
    var router = try newRouter();
    defer router.deinit();

    const mid = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.setHeader("X-Middleware", "applied");
            try ctx.next();
        }
    }.middle;

    var tc = try runTest(router, &.{mid}, harness.textHandler("OK"));
    defer tc.deinit();

    try harness.expectHeader(tc.ctx, "X-Middleware", "applied");
    try harness.expectBody(tc.ctx, "OK");
}

test "Middleware: not calling next stops the chain" {
    var router = try newRouter();
    defer router.deinit();

    const mid = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.text("Blocked", .{ .status = .forbidden });
            // Deliberately no `next()`: the handler must never run.
        }
    }.middle;

    var tc = try runTest(router, &.{mid}, harness.textHandler("Should not reach here"));
    defer tc.deinit();

    try harness.expectStatus(tc.ctx, .forbidden);
    try harness.expectBody(tc.ctx, "Blocked");
}

test "Middleware: several middlewares run in registration order" {
    var router = try newRouter();
    defer router.deinit();

    const mid1 = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.text("1", .{});
            try ctx.next();
        }
    }.middle;
    const mid2 = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.text("2", .{});
            try ctx.next();
        }
    }.middle;
    const mid3 = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.text("3", .{});
            try ctx.next();
        }
    }.middle;

    var tc = try runTest(router, &.{ mid1, mid2, mid3 }, harness.textHandler("H"));
    defer tc.deinit();

    try harness.expectBody(tc.ctx, "123H");
}

test "Middleware: after-hooks unwind in reverse order" {
    var router = try newRouter();
    defer router.deinit();

    harness.Trace.reset();

    var tc = try runTest(
        router,
        &.{ harness.tracingMiddleware("a"), harness.tracingMiddleware("b") },
        harness.tracingHandler("handler", "done"),
    );
    defer tc.deinit();

    try harness.Trace.expectOrder(&.{
        "a:before",
        "b:before",
        "handler",
        "b:after",
        "a:after",
    });
}

test "Middleware: can modify the response status" {
    var router = try newRouter();
    defer router.deinit();

    const mid = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.next();
            try ctx.setStatus(.accepted);
        }
    }.middle;

    var tc = try runTest(router, &.{mid}, harness.textHandler("body"));
    defer tc.deinit();

    // The middleware's post-hook wins over the handler's status.
    try harness.expectStatus(tc.ctx, .accepted);
}

test "Middleware: can add several headers" {
    var router = try newRouter();
    defer router.deinit();

    const mid = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.setHeader("X-First", "1");
            try ctx.setHeader("X-Second", "2");
            try ctx.setHeader("X-Third", "3");
            try ctx.next();
        }
    }.middle;

    var tc = try runTest(router, &.{mid}, harness.textHandler("OK"));
    defer tc.deinit();

    try harness.expectHeader(tc.ctx, "X-First", "1");
    try harness.expectHeader(tc.ctx, "X-Second", "2");
    try harness.expectHeader(tc.ctx, "X-Third", "3");
}

test "Middleware: a complex chain composes before and after work" {
    var router = try newRouter();
    defer router.deinit();

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

    var tc = try runTest(router, &.{ outer, inner }, harness.textHandler("core"));
    defer tc.deinit();

    try harness.expectBody(tc.ctx, "[(core)]");
    try harness.expectHeader(tc.ctx, "X-Outer", "in");
}

test "Middleware: a route with no middleware runs just its handler" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/test", harness.textHandler("bare"));

    var tc = try harness.newContext(testing.allocator, .{ .method = .GET, .target = "/test" });
    defer tc.deinit();

    const route = try router.getRoute(.GET, "/test");
    try testing.expectEqual(@as(usize, 1), route.handlers.items.len);

    try harness.runChain(tc.ctx, route);
    try harness.expectBody(tc.ctx, "bare");
}

test "Middleware: several routes share the same middleware" {
    var router = try newRouter();
    defer router.deinit();

    const mid = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.setHeader("X-Middleware-Applied", "yes");
            try ctx.next();
        }
    }.middle;

    try router.use(&.{mid});
    try router.get("/route1", harness.textHandler("route1"));
    try router.get("/route2", harness.textHandler("route2"));

    {
        var tc = try harness.newContext(testing.allocator, .{ .target = "/route1" });
        defer tc.deinit();
        try harness.runChain(tc.ctx, try router.getRoute(.GET, "/route1"));

        try harness.expectBody(tc.ctx, "route1");
        try harness.expectHeader(tc.ctx, "X-Middleware-Applied", "yes");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{ .target = "/route2" });
        defer tc.deinit();
        try harness.runChain(tc.ctx, try router.getRoute(.GET, "/route2"));

        try harness.expectBody(tc.ctx, "route2");
        try harness.expectHeader(tc.ctx, "X-Middleware-Applied", "yes");
    }
}

test "Middleware: an error in a middleware aborts the chain" {
    var router = try newRouter();
    defer router.deinit();

    harness.Trace.reset();

    try router.use(&.{harness.failingHandler(error.MiddlewareRejected)});
    try router.get("/test", harness.tracingHandler("handler", "never"));

    var tc = try harness.newContext(testing.allocator, .{ .target = "/test" });
    defer tc.deinit();

    const route = try router.getRoute(.GET, "/test");
    try testing.expectError(error.MiddlewareRejected, harness.runChain(tc.ctx, route));

    // The handler must not have run.
    try harness.Trace.expectOrder(&.{});
}

test "Middleware: an error in the handler propagates out through middleware" {
    var router = try newRouter();
    defer router.deinit();

    harness.Trace.reset();

    try router.use(&.{harness.tracingMiddleware("mw")});
    try router.get("/test", harness.failingHandler(error.HandlerFailed));

    var tc = try harness.newContext(testing.allocator, .{ .target = "/test" });
    defer tc.deinit();

    const route = try router.getRoute(.GET, "/test");
    try testing.expectError(error.HandlerFailed, harness.runChain(tc.ctx, route));

    // The middleware's after-hook is skipped, since `try next()` propagates.
    try harness.Trace.expectOrder(&.{"mw:before"});
}

// ---------------------------------------------------------------------------
// Built-in CORS middleware
// ---------------------------------------------------------------------------

test "Middleware.cors: echoes a wildcard origin when none is supplied" {
    var router = try newRouter();
    defer router.deinit();

    var tc = try runTest(router, &.{zinc.Middleware.cors()}, harness.textHandler("body"));
    defer tc.deinit();

    try harness.expectHeader(tc.ctx, "Access-Control-Allow-Origin", "*");
    try harness.expectBody(tc.ctx, "body");
}

test "Middleware.cors: echoes the request's Origin header" {
    var router = try newRouter();
    defer router.deinit();

    try router.use(&.{zinc.Middleware.cors()});
    try router.get("/test", harness.textHandler("body"));

    var tc = try harness.newContext(testing.allocator, .{ .method = .GET, .target = "/test" });
    defer tc.deinit();

    try tc.ctx.request.setHeader("Origin", "https://example.com");
    try harness.runChain(tc.ctx, try router.getRoute(.GET, "/test"));

    try harness.expectHeader(tc.ctx, "Access-Control-Allow-Origin", "https://example.com");
}

test "Middleware.cors: answers a preflight without running the handler" {
    var router = try newRouter();
    defer router.deinit();

    harness.Trace.reset();

    try router.use(&.{zinc.Middleware.cors()});
    try router.get("/test", harness.tracingHandler("handler", "should not run"));

    var tc = try harness.newContext(testing.allocator, .{ .method = .OPTIONS, .target = "/test" });
    defer tc.deinit();

    // An OPTIONS request resolves to the GET route (the router's CORS
    // affordance), and the middleware short-circuits it.
    try harness.runChain(tc.ctx, try router.getRoute(.OPTIONS, "/test"));

    try harness.expectStatus(tc.ctx, .no_content);
    try harness.expectHeader(tc.ctx, "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    try harness.expectHeader(tc.ctx, "Access-Control-Allow-Headers", "Content-Type");
    try harness.expectHeader(tc.ctx, "Access-Control-Allow-Private-Network", "true");
    try harness.Trace.expectOrder(&.{});
    try harness.expectNoBody(tc.ctx);
}

test "Middleware.cors: a non-preflight request reaches the handler" {
    var router = try newRouter();
    defer router.deinit();

    harness.Trace.reset();

    var tc = try runTest(
        router,
        &.{zinc.Middleware.cors()},
        harness.tracingHandler("handler", "reached"),
    );
    defer tc.deinit();

    try harness.Trace.expectOrder(&.{"handler"});
    try harness.expectBody(tc.ctx, "reached");
    try harness.expectNoHeader(tc.ctx, "Access-Control-Allow-Methods");
}

test "Middleware.cors: composes with another middleware" {
    var router = try newRouter();
    defer router.deinit();

    const tagger = struct {
        fn middle(ctx: *Context) anyerror!void {
            try ctx.setHeader("X-Tagged", "1");
            try ctx.next();
        }
    }.middle;

    var tc = try runTest(
        router,
        &.{ zinc.Middleware.cors(), tagger },
        harness.textHandler("body"),
    );
    defer tc.deinit();

    try harness.expectHeader(tc.ctx, "Access-Control-Allow-Origin", "*");
    try harness.expectHeader(tc.ctx, "X-Tagged", "1");
    try harness.expectBody(tc.ctx, "body");
}
