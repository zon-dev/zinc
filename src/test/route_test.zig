//! Tests for `zinc.Route`, a single (method, path, handler-chain) entry.
//!
//! The previous version of this file built a table of expectations and then
//! discarded every one of them in a loop that only did `_ = tc`. These tests
//! actually assert the matching rules.
//!
//! Two constructors exist with different ownership rules:
//!   * `Route.init` borrows the path (caller keeps ownership)
//!   * `Route.create` dupes the path and sets `path_owned`, so `deinit` frees it

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const RouteError = Route.RouteError;
const HandlerFn = zinc.HandlerFn;

const harness = @import("harness.zig");

/// `Route.init` with a borrowed path. Note the route is created with a fresh
/// empty handler list regardless of what is passed in.
fn borrowedRoute(method: std.http.Method, path: []const u8) !*Route {
    return Route.init(.{
        .method = method,
        .path = path,
        .allocator = testing.allocator,
        .handlers = std.array_list.Managed(HandlerFn).init(testing.allocator),
    });
}

test "Route: init records method and path" {
    const route = try borrowedRoute(.GET, "/foo");
    defer route.deinit();

    try testing.expectEqual(std.http.Method.GET, route.method);
    try testing.expectEqualStrings("/foo", route.path);
    try testing.expectEqualStrings("/foo", route.getPath());
    try testing.expectEqual(@as(usize, 0), route.handlers.items.len);
    try testing.expect(!route.path_owned);
}

test "Route: create owns its path and copies handlers" {
    const handler = harness.textHandler("hi");
    const route = try Route.create(testing.allocator, "/created", .POST, &.{handler});
    defer route.deinit();

    try testing.expectEqual(std.http.Method.POST, route.method);
    try testing.expectEqualStrings("/created", route.path);
    try testing.expect(route.path_owned);
    try testing.expectEqual(@as(usize, 1), route.handlers.items.len);
}

test "Route: create copies the path rather than aliasing it" {
    var path = "/mutable".*;
    const route = try Route.create(testing.allocator, &path, .GET, &.{});
    defer route.deinit();

    path[1] = 'X';

    try testing.expectEqualStrings("/mutable", route.path);
}

test "Route: create accepts several handlers in order" {
    const first = harness.textHandler("a");
    const second = harness.textHandler("b");
    const route = try Route.create(testing.allocator, "/multi", .GET, &.{ first, second });
    defer route.deinit();

    try testing.expectEqual(@as(usize, 2), route.handlers.items.len);
    try testing.expectEqual(first, route.handlers.items[0]);
    try testing.expectEqual(second, route.handlers.items[1]);
}

test "Route: create with an empty handler list" {
    const route = try Route.create(testing.allocator, "/empty", .GET, &.{});
    defer route.deinit();

    try testing.expectEqual(@as(usize, 0), route.handlers.items.len);
}

// ---------------------------------------------------------------------------
// Method matching
// ---------------------------------------------------------------------------

test "Route: isMethodAllowed accepts only its own method" {
    const route = try borrowedRoute(.GET, "/foo");
    defer route.deinit();

    try testing.expect(route.isMethodAllowed(.GET));
    try testing.expect(!route.isMethodAllowed(.POST));
    try testing.expect(!route.isMethodAllowed(.PUT));
    try testing.expect(!route.isMethodAllowed(.DELETE));
    try testing.expect(!route.isMethodAllowed(.OPTIONS));
}

test "Route: isMethodAllowed for every method" {
    const methods = [_]std.http.Method{
        .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS, .HEAD, .CONNECT, .TRACE,
    };

    for (methods) |owned| {
        const route = try borrowedRoute(owned, "/any");
        defer route.deinit();

        for (methods) |candidate| {
            const expected = owned == candidate;
            try testing.expectEqual(expected, route.isMethodAllowed(candidate));
        }
    }
}

// ---------------------------------------------------------------------------
// Path matching
// ---------------------------------------------------------------------------

test "Route: isPathMatch requires an exact path" {
    const route = try borrowedRoute(.GET, "/foo");
    defer route.deinit();

    try testing.expect(route.isPathMatch("/foo"));
    try testing.expect(!route.isPathMatch("/bar"));
    try testing.expect(!route.isPathMatch("/foo/bar"));
    try testing.expect(!route.isPathMatch("foo"));
    try testing.expect(!route.isPathMatch("/"));
    try testing.expect(!route.isPathMatch(""));
}

test "Route: isPathMatch ignores case" {
    const route = try borrowedRoute(.GET, "/Foo");
    defer route.deinit();

    try testing.expect(route.isPathMatch("/foo"));
    try testing.expect(route.isPathMatch("/FOO"));
}

test "Route: a wildcard path matches anything" {
    const route = try borrowedRoute(.GET, "*");
    defer route.deinit();

    try testing.expect(route.isPathMatch("/"));
    try testing.expect(route.isPathMatch("/anything"));
    try testing.expect(route.isPathMatch("/deeply/nested/path"));
    try testing.expect(route.isPathMatch(""));
}

test "Route: isPathMatch does not treat a query string as part of the path" {
    const route = try borrowedRoute(.GET, "/foo");
    defer route.deinit();

    // Query stripping is the router's job; a route compares whole strings.
    try testing.expect(!route.isPathMatch("/foo?code=123"));
}

// ---------------------------------------------------------------------------
// isMatch — method and path together
// ---------------------------------------------------------------------------

test "Route: isMatch requires both method and path" {
    const route = try borrowedRoute(.GET, "/foo");
    defer route.deinit();

    try testing.expect(route.isMatch(.GET, "/foo"));
    try testing.expect(!route.isMatch(.POST, "/foo"));
    try testing.expect(!route.isMatch(.GET, "/bar"));
    try testing.expect(!route.isMatch(.POST, "/bar"));
}

test "Route: a wildcard route still enforces the method" {
    const route = try borrowedRoute(.GET, "*");
    defer route.deinit();

    try testing.expect(route.isMatch(.GET, "/whatever"));
    try testing.expect(!route.isMatch(.POST, "/whatever"));
}

// ---------------------------------------------------------------------------
// isStaticRoute
// ---------------------------------------------------------------------------

test "Route: isStaticRoute matches on the first path segment" {
    const route = try borrowedRoute(.GET, "/assets/style.css");
    defer route.deinit();

    try testing.expect(route.isStaticRoute("/assets/style.css"));
    try testing.expect(route.isStaticRoute("/assets/other.css"));
    try testing.expect(!route.isStaticRoute("/other/style.css"));
}

test "Route: isStaticRoute is false for the server root" {
    const route = try borrowedRoute(.GET, "/assets");
    defer route.deinit();

    try testing.expect(!route.isStaticRoute("/"));
}

test "Route: a root route is never a static route" {
    const route = try borrowedRoute(.GET, "/");
    defer route.deinit();

    try testing.expect(!route.isStaticRoute("/anything"));
}

test "Route: a wildcard route is always a static route" {
    const route = try borrowedRoute(.GET, "*");
    defer route.deinit();

    try testing.expect(route.isStaticRoute("/"));
    try testing.expect(route.isStaticRoute("/assets/style.css"));
}

// ---------------------------------------------------------------------------
// Handler chain management
// ---------------------------------------------------------------------------

test "Route: use appends handlers to an empty route" {
    const route = try Route.create(testing.allocator, "/use", .GET, &.{});
    defer route.deinit();

    const handler = harness.textHandler("body");
    try route.use(&.{handler});

    try testing.expectEqual(@as(usize, 1), route.handlers.items.len);
    try testing.expectEqual(handler, route.handlers.items[0]);
}

test "Route: use appends after existing handlers" {
    const first = harness.textHandler("first");
    const route = try Route.create(testing.allocator, "/use", .GET, &.{first});
    defer route.deinit();

    const second = harness.textHandler("second");
    try route.use(&.{second});

    try testing.expectEqual(@as(usize, 2), route.handlers.items.len);
    try testing.expectEqual(first, route.handlers.items[0]);
    try testing.expectEqual(second, route.handlers.items[1]);
}

test "Route: use accepts several handlers at once" {
    const route = try Route.create(testing.allocator, "/use", .GET, &.{});
    defer route.deinit();

    try route.use(&.{ harness.noopHandler, harness.textHandler("x") });

    try testing.expectEqual(@as(usize, 2), route.handlers.items.len);
}

test "Route: use with an empty slice changes nothing" {
    const route = try Route.create(testing.allocator, "/use", .GET, &.{harness.noopHandler});
    defer route.deinit();

    try route.use(&.{});

    try testing.expectEqual(@as(usize, 1), route.handlers.items.len);
}

test "Route: isHandlerExists finds a registered handler" {
    const handler = harness.textHandler("registered");
    const route = try Route.create(testing.allocator, "/h", .GET, &.{handler});
    defer route.deinit();

    try testing.expect(route.isHandlerExists(handler));
    try testing.expect(!route.isHandlerExists(harness.noopHandler));
}

test "Route: isHandlerExists is false on an empty route" {
    const route = try Route.create(testing.allocator, "/h", .GET, &.{});
    defer route.deinit();

    try testing.expect(!route.isHandlerExists(harness.noopHandler));
}

test "Route: handle runs the route's chain against a context" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/run" });
    defer tc.deinit();

    const route = try Route.create(
        testing.allocator,
        "/run",
        .GET,
        &.{harness.textHandler("handled")},
    );
    defer route.deinit();

    // `Route.handle` would also try to write to a socket, so drive the chain.
    try harness.runChain(tc.ctx, route);

    try harness.expectBody(tc.ctx, "handled");
    try harness.expectStatus(tc.ctx, .ok);
}

test "Route: a chain of middleware runs in registration order" {
    harness.Trace.reset();

    var tc = try harness.newContext(testing.allocator, .{ .target = "/run" });
    defer tc.deinit();

    const route = try Route.create(testing.allocator, "/run", .GET, &.{
        harness.tracingMiddleware("mw"),
        harness.tracingHandler("handler", "ok"),
    });
    defer route.deinit();

    try harness.runChain(tc.ctx, route);

    try harness.Trace.expectOrder(&.{ "mw:before", "handler", "mw:after" });
}

test "Route: RouteError values are distinct" {
    // Guards against an accidental merge of the routing error cases, which
    // the router maps onto 404 and 405 respectively.
    try testing.expect(RouteError.NotFound != RouteError.MethodNotAllowed);
    try testing.expect(RouteError.NotFound != RouteError.HandlersEmpty);
    try testing.expect(RouteError.None != RouteError.NotFound);
}
