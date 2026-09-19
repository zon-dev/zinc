//! `zinc.Router`: registration, lookup and error mapping.
//!
//! Lookup rules:
//!   * `getRoute` strips a query string, and truncates at a space or `#`
//!   * OPTIONS falls back to a GET route on the same path (CORS)
//!   * `add` is idempotent: re-registering (method, path) is ignored
//!   * `use` applies middleware to routes registered before *and* after

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const RouteError = Route.RouteError;
const harness = @import("harness.zig");

test "Router: starts with no routes" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try testing.expectEqual(@as(usize, 0), harness.routeCount(app.router));
}

test "Router: verb helpers register distinct methods and run the handler" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    const handler = harness.text("ok");
    try app.router.get("/r", handler);
    try app.router.post("/r", handler);
    try app.router.put("/r", handler);
    try app.router.delete("/r", handler);
    try app.router.patch("/r", handler);
    try app.router.options("/r", handler);
    try app.router.head("/r", handler);
    try app.router.connect("/r", handler);
    try app.router.trace("/r", handler);

    for (harness.methods) |method| {
        try testing.expectEqual(method, (try app.router.getRoute(method, "/r")).method);
    }

    var res = try app.get("/r");
    defer res.deinit();
    try res.expectStatus(.ok);
    try res.expectBody("ok");
}

test "Router: distinct paths produce distinct routes" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/a", harness.text("a"));
    try app.router.get("/b", harness.text("b"));
    try app.router.get("/a/nested", harness.text("nested"));

    try testing.expectEqual(@as(usize, 3), harness.routeCount(app.router));
    try testing.expectEqualStrings("/a", (try app.router.getRoute(.GET, "/a")).path);
    try testing.expectEqualStrings("/b", (try app.router.getRoute(.GET, "/b")).path);
    try testing.expectEqualStrings("/a/nested", (try app.router.getRoute(.GET, "/a/nested")).path);
}

test "Router: re-registering the same method and path is ignored" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/dup", harness.text("first"));
    try app.router.get("/dup", harness.text("second"));
    try testing.expectEqual(@as(usize, 1), harness.routeCount(app.router));

    var res = try app.get("/dup");
    defer res.deinit();
    try res.expectBody("first");
}

test "Router: any / addAny / add" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    try app.router.any("/all", harness.text("all"));
    for (harness.methods) |method| {
        try testing.expectEqual(method, (try app.router.getRoute(method, "/all")).method);
    }
    try testing.expectEqual(@as(usize, harness.methods.len), harness.routeCount(app.router));

    try app.router.addAny(&.{ .GET, .POST }, "/some", harness.text("some"));
    try testing.expectEqual(std.http.Method.GET, (try app.router.getRoute(.GET, "/some")).method);
    try testing.expectEqual(std.http.Method.POST, (try app.router.getRoute(.POST, "/some")).method);
    try testing.expectError(RouteError.MethodNotAllowed, app.router.getRoute(.PUT, "/some"));

    try app.router.add(.DELETE, "/thing", harness.text("gone"));
    try testing.expectEqual(std.http.Method.DELETE, (try app.router.getRoute(.DELETE, "/thing")).method);

    const route = try Route.create(testing.allocator, "/manual", .GET, &.{harness.text("manual")});
    try app.router.addRoute(route);
    try testing.expectEqual(route, try app.router.getRoute(.GET, "/manual"));
}

test "Router: getRoute normalizes query, fragment and trailing request-line space" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/static", harness.text("s"));
    const expected = try app.router.getRoute(.GET, "/static");

    const targets = [_][]const u8{
        "/static?code=123",
        "/static?code=123&state=xyz",
        "/static?",
        "/static#anchor",
        "/static HTTP/1.1",
        "/static?code=123&state=xyz#foo",
    };
    for (targets) |target| {
        try testing.expectEqual(expected, try app.router.getRoute(.GET, target));
    }
}

test "Router: lookup failures" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/static", harness.text("s"));
    try app.router.get("/a/b", harness.text("b"));

    try testing.expectError(RouteError.NotFound, app.router.getRoute(.GET, "/nope"));
    try testing.expectError(RouteError.NotFound, app.router.getRoute(.GET, "/static/deeper"));
    try testing.expectError(RouteError.NotFound, app.router.getRoute(.GET, "/foo/static"));
    try testing.expectError(RouteError.NotFound, app.router.getRoute(.GET, "/a"));
    try testing.expectError(RouteError.MethodNotAllowed, app.router.getRoute(.POST, "/static"));
    try testing.expectError(RouteError.MethodNotAllowed, app.router.getRoute(.PUT, "/static"));
    try testing.expectError(RouteError.MethodNotAllowed, app.router.getRoute(.DELETE, "/static"));
    try testing.expectError(RouteError.MethodNotAllowed, app.router.getRoute(.HEAD, "/static"));

    var empty = try harness.App.init(testing.allocator);
    defer empty.deinit();
    try testing.expectError(RouteError.NotFound, empty.router.getRoute(.GET, "/"));
    try testing.expectError(RouteError.NotFound, empty.router.getRoute(.GET, "/anything"));
}

test "Router: OPTIONS falls back to GET unless an OPTIONS route exists" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/cors", harness.text("get"));

    try testing.expectEqual(std.http.Method.GET, (try app.router.getRoute(.OPTIONS, "/cors")).method);

    try app.router.options("/cors", harness.text("options"));
    try testing.expectEqual(std.http.Method.OPTIONS, (try app.router.getRoute(.OPTIONS, "/cors")).method);
}

test "Router: prepareContext runs the matching route and surfaces lookup errors" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/hello", harness.text("Hello Zinc!"));

    var ok = try harness.newContext(testing.allocator, .{ .method = .GET, .target = "/hello" });
    defer ok.deinit();
    app.router.prepareContext(ok.ctx) catch {};
    try harness.expectBody(ok.ctx, "Hello Zinc!");

    var missing = try harness.newContext(testing.allocator, .{ .target = "/missing" });
    defer missing.deinit();
    try testing.expectError(RouteError.NotFound, app.router.prepareContext(missing.ctx));

    var bad_method = try harness.newContext(testing.allocator, .{ .method = .PUT, .target = "/hello" });
    defer bad_method.deinit();
    try testing.expectError(RouteError.MethodNotAllowed, app.router.prepareContext(bad_method.ctx));
}

test "Router: use applies middleware before and after registration" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    try app.router.get("/before", harness.text("body"));
    try app.router.use(&.{ harness.tracingMiddleware("m1"), harness.tracingMiddleware("m2") });
    try app.router.get("/after", harness.text("body"));

    try testing.expectEqual(@as(usize, 3), (try app.router.getRoute(.GET, "/before")).handlers.items.len);
    try testing.expectEqual(@as(usize, 3), (try app.router.getRoute(.GET, "/after")).handlers.items.len);

    try app.router.get("/order", harness.tracingHandler("handler", "done"));
    harness.Trace.reset();
    var res = try app.get("/order");
    defer res.deinit();
    try harness.Trace.expectOrder(&.{
        "m1:before", "m2:before", "handler", "m2:after", "m1:after",
    });
    try res.expectBody("done");
}

test "Router: use with no handlers leaves routes untouched" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.get("/plain", harness.text("plain"));
    try app.router.use(&.{});
    try testing.expectEqual(@as(usize, 1), (try app.router.getRoute(.GET, "/plain")).handlers.items.len);
}

test "Router: the built-in CORS middleware sets an allow-origin header" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.use(&.{zinc.Middleware.cors()});
    try app.router.get("/cors", harness.text("body"));

    var res = try app.get("/cors");
    defer res.deinit();
    try res.expectHeader("Access-Control-Allow-Origin", "*");
    try res.expectBody("body");
}

test "Router: catchers are keyed by status and replace on re-set" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    const not_found = harness.text("404");
    const not_allowed = harness.text("405");
    try app.router.setCatcher(.not_found, not_found);
    try app.router.setCatcher(.method_not_allowed, not_allowed);
    try testing.expectEqual(not_found, app.router.catchers.?.get(.not_found).?);
    try testing.expectEqual(not_allowed, app.router.catchers.?.get(.method_not_allowed).?);
    try testing.expect(app.router.catchers.?.get(.internal_server_error) == null);

    const second = harness.text("second");
    try app.router.setCatcher(.not_found, second);
    try testing.expectEqual(second, app.router.catchers.?.get(.not_found).?);
}

test "Router: group returns a group carrying the prefix" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    var group = try app.router.group("/api");
    defer group.deinit();
    try testing.expectEqualStrings("/api", group.prefix);
    try testing.expectEqual(app.router, group.router);
    try group.get("/users", harness.text("users"));
    try testing.expectEqualStrings("/api/users", (try app.router.getRoute(.GET, "/api/users")).path);
}
