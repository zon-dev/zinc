const std = @import("std");
const zinc = @import("../zinc.zig");
const expect = std.testing.expect;

const Context = zinc.Context;
const Request = zinc.Request;
const Response = zinc.Response;

test "Middleware: basic chain with before and after" {
    const allocator = std.testing.allocator;

    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

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
            try ctx.text("world", .{});
        }
    }.anyHandle;

    try router.use(&.{ mid1, mid2 });
    try router.get("/test", handle);

    const routes = router.getRoutes();
    defer routes.deinit();

    try std.testing.expectEqual(1, routes.items.len);
    try std.testing.expectEqual(3, routes.items[0].handlers.items.len);

    var ctx_get = try createContext(allocator, .GET, "/test");
    defer ctx_get.destroy();

    const route = try router.getRoute(ctx_get.request.method, ctx_get.request.target);
    ctx_get.handlers = route.handlers;
    try ctx_get.handlersProcess();
    try std.testing.expectEqual(.ok, ctx_get.response.status);
    try std.testing.expectEqual(3, ctx_get.handlers.items.len);
    try std.testing.expectEqualStrings("Hello world!", ctx_get.response.body orelse "");
}

test "Middleware: single middleware" {
    const allocator = std.testing.allocator;

    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    const mid = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.setHeader("X-Middleware", "applied");
            try ctx.next();
        }
    }.middle;

    const handle = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("OK", .{});
        }
    }.anyHandle;

    try router.use(&.{mid});
    try router.get("/test", handle);

    var ctx_get = try createContext(allocator, .GET, "/test");
    defer ctx_get.destroy();

    const route = try router.getRoute(ctx_get.request.method, ctx_get.request.target);
    ctx_get.handlers = route.handlers;
    try ctx_get.handlersProcess();

    const headers = ctx_get.response.getHeaders();
    var found_header = false;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "X-Middleware")) {
            try std.testing.expectEqualStrings(header.value, "applied");
            found_header = true;
            break;
        }
    }
    try std.testing.expect(found_header);
    try std.testing.expectEqualStrings(ctx_get.response.body orelse "", "OK");
}

test "Middleware: early termination without next()" {
    const allocator = std.testing.allocator;

    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    const mid = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Blocked", .{ .status = .forbidden });
            // Don't call next() - this should stop the chain
        }
    }.middle;

    const handle = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Should not reach here", .{});
        }
    }.anyHandle;

    try router.use(&.{mid});
    try router.get("/test", handle);

    var ctx_get = try createContext(allocator, .GET, "/test");
    defer ctx_get.destroy();

    const route = try router.getRoute(ctx_get.request.method, ctx_get.request.target);
    ctx_get.handlers = route.handlers;
    try ctx_get.handlersProcess();

    try std.testing.expectEqual(.forbidden, ctx_get.response.status);
    try std.testing.expectEqualStrings(ctx_get.response.body orelse "", "Blocked");
}

test "Middleware: multiple middlewares in sequence" {
    const allocator = std.testing.allocator;

    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    const mid1 = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("1", .{});
            try ctx.next();
        }
    }.middle;

    const mid2 = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("2", .{});
            try ctx.next();
        }
    }.middle;

    const mid3 = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("3", .{});
            try ctx.next();
        }
    }.middle;

    const handle = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("handler", .{});
        }
    }.anyHandle;

    try router.use(&.{ mid1, mid2, mid3 });
    try router.get("/test", handle);

    var ctx_get = try createContext(allocator, .GET, "/test");
    defer ctx_get.destroy();

    const route = try router.getRoute(ctx_get.request.method, ctx_get.request.target);
    ctx_get.handlers = route.handlers;
    try ctx_get.handlersProcess();

    try std.testing.expectEqualStrings(ctx_get.response.body orelse "", "123handler");
}

test "Middleware: modify response status" {
    const allocator = std.testing.allocator;

    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    const mid = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.setStatus(.ok);
            try ctx.next();
            // After next() returns, handler might have changed status
            // So we set it again after the chain completes to ensure middleware wins
            try ctx.setStatus(.unauthorized);
        }
    }.middle;

    const handle = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            // Use text() but middleware will override status after next() returns
            try ctx.text("Content", .{ .status = .ok });
        }
    }.anyHandle;

    try router.use(&.{mid});
    try router.get("/test", handle);

    var ctx_get = try createContext(allocator, .GET, "/test");
    defer ctx_get.destroy();

    const route = try router.getRoute(ctx_get.request.method, ctx_get.request.target);
    ctx_get.handlers = route.handlers;
    try ctx_get.handlersProcess();

    // Middleware should have the final say on status
    try std.testing.expectEqual(.unauthorized, ctx_get.response.status);
}

test "Middleware: add multiple headers" {
    const allocator = std.testing.allocator;

    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    const mid = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.setHeader("X-Custom-1", "value1");
            try ctx.setHeader("X-Custom-2", "value2");
            try ctx.next();
        }
    }.middle;

    const handle = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("OK", .{});
        }
    }.anyHandle;

    try router.use(&.{mid});
    try router.get("/test", handle);

    var ctx_get = try createContext(allocator, .GET, "/test");
    defer ctx_get.destroy();

    const route = try router.getRoute(ctx_get.request.method, ctx_get.request.target);
    ctx_get.handlers = route.handlers;
    try ctx_get.handlersProcess();

    const headers = ctx_get.response.getHeaders();
    var found_header1 = false;
    var found_header2 = false;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "X-Custom-1")) {
            try std.testing.expectEqualStrings(header.value, "value1");
            found_header1 = true;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "X-Custom-2")) {
            try std.testing.expectEqualStrings(header.value, "value2");
            found_header2 = true;
        }
    }
    try std.testing.expect(found_header1);
    try std.testing.expect(found_header2);
}

test "Middleware: complex chain with before and after" {
    const allocator = std.testing.allocator;

    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    const mid1 = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("[", .{});
            try ctx.next();
            try ctx.text("]", .{});
        }
    }.middle;

    const mid2 = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("(", .{});
            try ctx.next();
            try ctx.text(")", .{});
        }
    }.middle;

    const handle = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("content", .{});
        }
    }.anyHandle;

    try router.use(&.{ mid1, mid2 });
    try router.get("/test", handle);

    var ctx_get = try createContext(allocator, .GET, "/test");
    defer ctx_get.destroy();

    const route = try router.getRoute(ctx_get.request.method, ctx_get.request.target);
    ctx_get.handlers = route.handlers;
    try ctx_get.handlersProcess();

    // Expected: [(content)]
    try std.testing.expectEqualStrings(ctx_get.response.body orelse "", "[(content)]");
}

test "Middleware: no middleware" {
    const allocator = std.testing.allocator;

    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    const handle = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Direct", .{});
        }
    }.anyHandle;

    try router.get("/test", handle);

    var ctx_get = try createContext(allocator, .GET, "/test");
    defer ctx_get.destroy();

    const route = try router.getRoute(ctx_get.request.method, ctx_get.request.target);
    ctx_get.handlers = route.handlers;
    try ctx_get.handlersProcess();

    try std.testing.expectEqual(1, ctx_get.handlers.items.len);
    try std.testing.expectEqualStrings(ctx_get.response.body orelse "", "Direct");
}

test "Middleware: multiple routes share middleware" {
    const allocator = std.testing.allocator;

    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    const mid = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            // Verify middleware is called by checking headers
            try ctx.setHeader("X-Middleware-Applied", "true");
            try ctx.next();
        }
    }.middle;

    const handle1 = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("route1", .{});
        }
    }.anyHandle;

    const handle2 = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("route2", .{});
        }
    }.anyHandle;

    try router.use(&.{mid});
    try router.get("/route1", handle1);
    try router.get("/route2", handle2);

    // Test route1
    var ctx1 = try createContext(allocator, .GET, "/route1");
    defer ctx1.destroy();
    const route1 = try router.getRoute(ctx1.request.method, ctx1.request.target);
    ctx1.handlers = route1.handlers;
    try ctx1.handlersProcess();
    try std.testing.expectEqualStrings(ctx1.response.body orelse "", "route1");

    // Verify middleware was applied
    const headers1 = ctx1.response.getHeaders();
    var found_middleware1 = false;
    for (headers1) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "X-Middleware-Applied")) {
            found_middleware1 = true;
            break;
        }
    }
    try std.testing.expect(found_middleware1);

    // Test route2
    var ctx2 = try createContext(allocator, .GET, "/route2");
    defer ctx2.destroy();
    const route2 = try router.getRoute(ctx2.request.method, ctx2.request.target);
    ctx2.handlers = route2.handlers;
    try ctx2.handlersProcess();
    try std.testing.expectEqualStrings(ctx2.response.body orelse "", "route2");

    // Verify middleware was applied
    const headers2 = ctx2.response.getHeaders();
    var found_middleware2 = false;
    for (headers2) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "X-Middleware-Applied")) {
            found_middleware2 = true;
            break;
        }
    }
    try std.testing.expect(found_middleware2);
}

fn createContext(allocator: std.mem.Allocator, method: std.http.Method, target: []const u8) anyerror!*Context {
    const req = try Request.init(.{ .allocator = allocator, .method = method, .target = target });
    const res = try Response.init(.{ .allocator = allocator });
    return try Context.init(.{ .allocator = allocator, .request = req, .response = res });
}
