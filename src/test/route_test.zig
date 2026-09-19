//! `zinc.Route`: one (method, path, handler-chain) entry.
//!
//! `Route.init` borrows the path; `Route.create` dupes it (`path_owned`).

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const RouteError = Route.RouteError;
const harness = @import("harness.zig");

test "Route: init records method and path; create owns a copy" {
    const borrowed = try harness.borrowedRoute(testing.allocator, .GET, "/foo");
    defer borrowed.deinit();
    try testing.expectEqual(std.http.Method.GET, borrowed.method);
    try testing.expectEqualStrings("/foo", borrowed.path);
    try testing.expectEqualStrings("/foo", borrowed.getPath());
    try testing.expectEqual(@as(usize, 0), borrowed.handlers.items.len);
    try testing.expect(!borrowed.path_owned);

    const handler = harness.text("hi");
    const created = try Route.create(testing.allocator, "/created", .POST, &.{handler});
    defer created.deinit();
    try testing.expectEqual(std.http.Method.POST, created.method);
    try testing.expect(created.path_owned);
    try testing.expectEqual(@as(usize, 1), created.handlers.items.len);

    var path = "/mutable".*;
    const copy = try Route.create(testing.allocator, &path, .GET, &.{});
    defer copy.deinit();
    path[1] = 'X';
    try testing.expectEqualStrings("/mutable", copy.path);

    const first = harness.text("a");
    const second = harness.text("b");
    const multi = try Route.create(testing.allocator, "/multi", .GET, &.{ first, second });
    defer multi.deinit();
    try testing.expectEqual(first, multi.handlers.items[0]);
    try testing.expectEqual(second, multi.handlers.items[1]);

    const empty = try Route.create(testing.allocator, "/empty", .GET, &.{});
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.handlers.items.len);
}

test "Route: isMethodAllowed accepts only its own method" {
    for (harness.methods) |owned| {
        const route = try harness.borrowedRoute(testing.allocator, owned, "/any");
        defer route.deinit();
        for (harness.methods) |candidate| {
            try testing.expectEqual(owned == candidate, route.isMethodAllowed(candidate));
        }
    }
}

test "Route: isPathMatch is exact, case-insensitive, and treats * as a wildcard" {
    const route = try harness.borrowedRoute(testing.allocator, .GET, "/Foo");
    defer route.deinit();
    try testing.expect(route.isPathMatch("/foo"));
    try testing.expect(route.isPathMatch("/FOO"));
    try testing.expect(!route.isPathMatch("/bar"));
    try testing.expect(!route.isPathMatch("/foo/bar"));
    try testing.expect(!route.isPathMatch("foo"));
    try testing.expect(!route.isPathMatch("/"));
    try testing.expect(!route.isPathMatch(""));
    try testing.expect(!route.isPathMatch("/foo?code=123"));

    const wild = try harness.borrowedRoute(testing.allocator, .GET, "*");
    defer wild.deinit();
    try testing.expect(wild.isPathMatch("/"));
    try testing.expect(wild.isPathMatch("/anything"));
    try testing.expect(wild.isPathMatch("/deeply/nested/path"));
    try testing.expect(wild.isPathMatch(""));
}

test "Route: isMatch requires both method and path" {
    const route = try harness.borrowedRoute(testing.allocator, .GET, "/foo");
    defer route.deinit();
    try testing.expect(route.isMatch(.GET, "/foo"));
    try testing.expect(!route.isMatch(.POST, "/foo"));
    try testing.expect(!route.isMatch(.GET, "/bar"));

    const wild = try harness.borrowedRoute(testing.allocator, .GET, "*");
    defer wild.deinit();
    try testing.expect(wild.isMatch(.GET, "/whatever"));
    try testing.expect(!wild.isMatch(.POST, "/whatever"));
}

test "Route: isStaticRoute matches the first path segment" {
    const assets = try harness.borrowedRoute(testing.allocator, .GET, "/assets/style.css");
    defer assets.deinit();
    try testing.expect(assets.isStaticRoute("/assets/style.css"));
    try testing.expect(assets.isStaticRoute("/assets/other.css"));
    try testing.expect(!assets.isStaticRoute("/other/style.css"));

    const prefix = try harness.borrowedRoute(testing.allocator, .GET, "/assets");
    defer prefix.deinit();
    try testing.expect(!prefix.isStaticRoute("/"));

    const root = try harness.borrowedRoute(testing.allocator, .GET, "/");
    defer root.deinit();
    try testing.expect(!root.isStaticRoute("/anything"));

    const wild = try harness.borrowedRoute(testing.allocator, .GET, "*");
    defer wild.deinit();
    try testing.expect(wild.isStaticRoute("/"));
    try testing.expect(wild.isStaticRoute("/assets/style.css"));
}

test "Route: use appends handlers; isHandlerExists finds them" {
    const first = harness.text("first");
    const route = try Route.create(testing.allocator, "/use", .GET, &.{first});
    defer route.deinit();

    const second = harness.text("second");
    try route.use(&.{second});
    try route.use(&.{ harness.noopHandler, harness.text("x") });
    try route.use(&.{});

    try testing.expectEqual(@as(usize, 4), route.handlers.items.len);
    try testing.expectEqual(first, route.handlers.items[0]);
    try testing.expect(route.isHandlerExists(first));
    try testing.expect(!route.isHandlerExists(harness.text("absent")));

    const empty = try Route.create(testing.allocator, "/h", .GET, &.{});
    defer empty.deinit();
    try testing.expect(!empty.isHandlerExists(harness.noopHandler));
}

test "Route: handle runs the chain against a context" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.addRoute(try Route.create(
        testing.allocator,
        "/run",
        .GET,
        &.{ harness.tracingMiddleware("mw"), harness.tracingHandler("handler", "handled") },
    ));

    harness.Trace.reset();
    var res = try app.get("/run");
    defer res.deinit();
    try res.expectBody("handled");
    try res.expectStatus(.ok);
    try harness.Trace.expectOrder(&.{ "mw:before", "handler", "mw:after" });
}

test "Route: RouteError values are distinct" {
    try testing.expect(RouteError.NotFound != RouteError.MethodNotAllowed);
    try testing.expect(RouteError.NotFound != RouteError.HandlersEmpty);
    try testing.expect(RouteError.None != RouteError.NotFound);
}
