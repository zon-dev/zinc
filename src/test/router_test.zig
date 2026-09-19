//! Tests for `zinc.Router`: registration, lookup and error mapping.
//!
//! Lookup rules worth stating up front, because several are surprising:
//!   * `getRoute` strips a query string, and also truncates at a space or `#`
//!   * an OPTIONS request falls back to a GET route on the same path (CORS)
//!   * `add` is idempotent: registering an existing (method, path) is ignored
//!   * `use` applies middleware to routes registered *before* the call as well

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Context = zinc.Context;
const HandlerFn = zinc.HandlerFn;
const Route = zinc.Route;
const Router = zinc.Router;
const RouteError = Route.RouteError;

const harness = @import("harness.zig");

fn newRouter() !*Router {
    return Router.init(.{ .allocator = testing.allocator });
}

/// Number of routes currently registered.
fn routeCount(router: *Router) usize {
    const routes = router.getRoutes();
    defer routes.deinit();
    return routes.items.len;
}

test "Router: starts with no routes" {
    var router = try newRouter();
    defer router.deinit();

    try testing.expectEqual(@as(usize, 0), routeCount(router));
}

test "Router: get registers a route reachable by path" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/", harness.textHandler("Hello Zinc!"));

    try testing.expectEqual(@as(usize, 1), routeCount(router));
    const route = try router.getRoute(.GET, "/");
    try testing.expectEqualStrings("/", route.path);
    try testing.expectEqual(std.http.Method.GET, route.method);
}

test "Router: a registered handler runs against a context" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/", harness.textHandler("Hello Zinc!"));

    var tc = try harness.newContext(testing.allocator, .{ .method = .GET, .target = "/" });
    defer tc.deinit();

    const route = try router.getRoute(.GET, "/");
    try harness.runChain(tc.ctx, route);

    try harness.expectStatus(tc.ctx, .ok);
    try harness.expectBody(tc.ctx, "Hello Zinc!");
}

test "Router: each verb helper registers its own method" {
    var router = try newRouter();
    defer router.deinit();

    const handler = harness.textHandler("ok");
    try router.get("/r", handler);
    try router.post("/r", handler);
    try router.put("/r", handler);
    try router.delete("/r", handler);
    try router.patch("/r", handler);
    try router.options("/r", handler);
    try router.head("/r", handler);
    try router.connect("/r", handler);
    try router.trace("/r", handler);

    const methods = [_]std.http.Method{
        .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS, .HEAD, .CONNECT, .TRACE,
    };
    for (methods) |method| {
        const route = try router.getRoute(method, "/r");
        try testing.expectEqual(method, route.method);
    }
}

test "Router: distinct paths produce distinct routes" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/a", harness.textHandler("a"));
    try router.get("/b", harness.textHandler("b"));
    try router.get("/a/nested", harness.textHandler("nested"));

    try testing.expectEqual(@as(usize, 3), routeCount(router));
    try testing.expectEqualStrings("/a", (try router.getRoute(.GET, "/a")).path);
    try testing.expectEqualStrings("/b", (try router.getRoute(.GET, "/b")).path);
    try testing.expectEqualStrings("/a/nested", (try router.getRoute(.GET, "/a/nested")).path);
}

test "Router: re-registering the same method and path is ignored" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/dup", harness.textHandler("first"));
    try router.get("/dup", harness.textHandler("second"));

    try testing.expectEqual(@as(usize, 1), routeCount(router));

    // The first registration wins; the second is dropped entirely.
    var tc = try harness.newContext(testing.allocator, .{ .target = "/dup" });
    defer tc.deinit();
    try harness.runChain(tc.ctx, try router.getRoute(.GET, "/dup"));
    try harness.expectBody(tc.ctx, "first");
}

test "Router: any registers every method on a path" {
    var router = try newRouter();
    defer router.deinit();

    try router.any("/all", harness.textHandler("all"));

    const methods = [_]std.http.Method{
        .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS, .HEAD, .CONNECT, .TRACE,
    };
    for (methods) |method| {
        const route = try router.getRoute(method, "/all");
        try testing.expectEqual(method, route.method);
    }
    try testing.expectEqual(@as(usize, methods.len), routeCount(router));
}

test "Router: addAny registers only the listed methods" {
    var router = try newRouter();
    defer router.deinit();

    try router.addAny(&.{ .GET, .POST }, "/some", harness.textHandler("some"));

    try testing.expectEqual(std.http.Method.GET, (try router.getRoute(.GET, "/some")).method);
    try testing.expectEqual(std.http.Method.POST, (try router.getRoute(.POST, "/some")).method);
    try testing.expectError(RouteError.MethodNotAllowed, router.getRoute(.PUT, "/some"));
}

test "Router: add registers a single method" {
    var router = try newRouter();
    defer router.deinit();

    try router.add(.DELETE, "/thing", harness.textHandler("gone"));

    try testing.expectEqual(std.http.Method.DELETE, (try router.getRoute(.DELETE, "/thing")).method);
}

test "Router: addRoute inserts a pre-built route" {
    var router = try newRouter();
    defer router.deinit();

    // The tree takes ownership, so no explicit deinit here.
    const route = try Route.create(
        testing.allocator,
        "/manual",
        .GET,
        &.{harness.textHandler("manual")},
    );
    try router.addRoute(route);

    try testing.expectEqual(route, try router.getRoute(.GET, "/manual"));
}

// ---------------------------------------------------------------------------
// Target normalization during lookup
// ---------------------------------------------------------------------------

test "Router: getRoute ignores a query string" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/static", harness.textHandler("s"));
    const expected = try router.getRoute(.GET, "/static");

    try testing.expectEqual(expected, try router.getRoute(.GET, "/static?code=123"));
    try testing.expectEqual(expected, try router.getRoute(.GET, "/static?code=123&state=xyz"));
    try testing.expectEqual(expected, try router.getRoute(.GET, "/static?"));
}

test "Router: getRoute truncates at a fragment" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/static", harness.textHandler("s"));
    const expected = try router.getRoute(.GET, "/static");

    try testing.expectEqual(expected, try router.getRoute(.GET, "/static#anchor"));
}

test "Router: getRoute truncates at a space" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/static", harness.textHandler("s"));
    const expected = try router.getRoute(.GET, "/static");

    // Guards the fast path that avoids URL parsing for space-terminated
    // targets taken straight out of the request line.
    try testing.expectEqual(expected, try router.getRoute(.GET, "/static HTTP/1.1"));
}

test "Router: getRoute handles a query string with a fragment" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/static", harness.textHandler("s"));
    const expected = try router.getRoute(.GET, "/static");

    try testing.expectEqual(expected, try router.getRoute(.GET, "/static?code=123&state=xyz#foo"));
}

// ---------------------------------------------------------------------------
// Lookup failures
// ---------------------------------------------------------------------------

test "Router: an unknown path is NotFound" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/static", harness.textHandler("s"));

    try testing.expectError(RouteError.NotFound, router.getRoute(.GET, "/nope"));
    try testing.expectError(RouteError.NotFound, router.getRoute(.GET, "/static/deeper"));
    try testing.expectError(RouteError.NotFound, router.getRoute(.GET, "/foo/static"));
}

test "Router: a known path with an unregistered method is MethodNotAllowed" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/static", harness.textHandler("s"));

    try testing.expectError(RouteError.MethodNotAllowed, router.getRoute(.POST, "/static"));
    try testing.expectError(RouteError.MethodNotAllowed, router.getRoute(.PUT, "/static"));
    try testing.expectError(RouteError.MethodNotAllowed, router.getRoute(.DELETE, "/static"));
}

test "Router: an empty router reports NotFound for everything" {
    var router = try newRouter();
    defer router.deinit();

    try testing.expectError(RouteError.NotFound, router.getRoute(.GET, "/"));
    try testing.expectError(RouteError.NotFound, router.getRoute(.GET, "/anything"));
}

test "Router: a path that exists only as an intermediate node is NotFound" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/a/b", harness.textHandler("b"));

    // `/a` is a node in the trie but carries no routes of its own.
    try testing.expectError(RouteError.NotFound, router.getRoute(.GET, "/a"));
}

test "Router: OPTIONS falls back to a GET route on the same path" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/cors", harness.textHandler("c"));

    // Deliberate CORS affordance: a preflight reaches the GET route.
    const via_options = try router.getRoute(.OPTIONS, "/cors");
    try testing.expectEqual(std.http.Method.GET, via_options.method);
}

test "Router: OPTIONS prefers its own route when one is registered" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/cors", harness.textHandler("get"));
    try router.options("/cors", harness.textHandler("options"));

    const route = try router.getRoute(.OPTIONS, "/cors");
    try testing.expectEqual(std.http.Method.OPTIONS, route.method);
}

test "Router: the GET fallback does not apply to other methods" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/only-get", harness.textHandler("g"));

    try testing.expectError(RouteError.MethodNotAllowed, router.getRoute(.POST, "/only-get"));
    try testing.expectError(RouteError.MethodNotAllowed, router.getRoute(.HEAD, "/only-get"));
}

// ---------------------------------------------------------------------------
// prepareContext / handleContext
// ---------------------------------------------------------------------------

test "Router: prepareContext runs the matching route" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/hello", harness.textHandler("Hello Zinc!"));

    var tc = try harness.newContext(testing.allocator, .{ .method = .GET, .target = "/hello" });
    defer tc.deinit();

    // `prepareContext` calls `Route.handle`, which runs the chain and then
    // attempts to write the response; the write fails on a context with no
    // socket, so only the handler's effect on the response is asserted.
    router.prepareContext(tc.ctx) catch {};

    try harness.expectBody(tc.ctx, "Hello Zinc!");
}

test "Router: prepareContext surfaces NotFound" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/", harness.textHandler("root"));

    var tc = try harness.newContext(testing.allocator, .{ .method = .GET, .target = "/missing" });
    defer tc.deinit();

    try testing.expectError(RouteError.NotFound, router.prepareContext(tc.ctx));
}

test "Router: prepareContext surfaces MethodNotAllowed" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/", harness.textHandler("root"));

    var tc = try harness.newContext(testing.allocator, .{ .method = .PUT, .target = "/" });
    defer tc.deinit();

    try testing.expectError(RouteError.MethodNotAllowed, router.prepareContext(tc.ctx));
}

// ---------------------------------------------------------------------------
// Middleware registration
// ---------------------------------------------------------------------------

test "Router: use prepends middleware to routes registered afterwards" {
    var router = try newRouter();
    defer router.deinit();

    try router.use(&.{harness.noopHandler});
    try router.get("/after", harness.textHandler("body"));

    const route = try router.getRoute(.GET, "/after");
    try testing.expectEqual(@as(usize, 2), route.handlers.items.len);
}

test "Router: use also applies to routes registered beforehand" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/before", harness.textHandler("body"));
    try router.use(&.{harness.noopHandler});

    // `use` calls `rebuild`, which walks the tree and appends to every route.
    const route = try router.getRoute(.GET, "/before");
    try testing.expectEqual(@as(usize, 2), route.handlers.items.len);
}

test "Router: several middlewares accumulate" {
    var router = try newRouter();
    defer router.deinit();

    try router.use(&.{ harness.noopHandler, harness.tracingMiddleware("m2") });
    try router.get("/multi", harness.textHandler("body"));

    const route = try router.getRoute(.GET, "/multi");
    try testing.expectEqual(@as(usize, 3), route.handlers.items.len);
}

test "Router: middleware runs before the handler" {
    var router = try newRouter();
    defer router.deinit();

    try router.use(&.{harness.tracingMiddleware("mw")});
    try router.get("/order", harness.tracingHandler("handler", "done"));

    var tc = try harness.newContext(testing.allocator, .{ .target = "/order" });
    defer tc.deinit();

    harness.Trace.reset();
    try harness.runChain(tc.ctx, try router.getRoute(.GET, "/order"));

    try harness.Trace.expectOrder(&.{ "mw:before", "handler", "mw:after" });
    try harness.expectBody(tc.ctx, "done");
}

test "Router: middleware is shared across routes" {
    var router = try newRouter();
    defer router.deinit();

    try router.use(&.{harness.noopHandler});
    try router.get("/one", harness.textHandler("one"));
    try router.get("/two", harness.textHandler("two"));

    try testing.expectEqual(@as(usize, 2), (try router.getRoute(.GET, "/one")).handlers.items.len);
    try testing.expectEqual(@as(usize, 2), (try router.getRoute(.GET, "/two")).handlers.items.len);
}

test "Router: use with no handlers leaves routes untouched" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/plain", harness.textHandler("plain"));
    try router.use(&.{});

    try testing.expectEqual(@as(usize, 1), (try router.getRoute(.GET, "/plain")).handlers.items.len);
}

test "Router: the built-in CORS middleware sets an allow-origin header" {
    var router = try newRouter();
    defer router.deinit();

    try router.use(&.{zinc.Middleware.cors()});
    try router.get("/cors", harness.textHandler("body"));

    var tc = try harness.newContext(testing.allocator, .{ .method = .GET, .target = "/cors" });
    defer tc.deinit();

    try harness.runChain(tc.ctx, try router.getRoute(.GET, "/cors"));

    try harness.expectHeader(tc.ctx, "Access-Control-Allow-Origin", "*");
    try harness.expectBody(tc.ctx, "body");
}

// ---------------------------------------------------------------------------
// Catchers
// ---------------------------------------------------------------------------

test "Router: setCatcher stores a handler retrievable from Catchers" {
    var router = try newRouter();
    defer router.deinit();

    const handler = harness.textHandler("not found");
    try router.setCatcher(.not_found, handler);

    try testing.expectEqual(handler, router.catchers.?.get(.not_found).?);
}

test "Router: catchers are keyed by status" {
    var router = try newRouter();
    defer router.deinit();

    const not_found = harness.textHandler("404");
    const not_allowed = harness.textHandler("405");
    try router.setCatcher(.not_found, not_found);
    try router.setCatcher(.method_not_allowed, not_allowed);

    try testing.expectEqual(not_found, router.catchers.?.get(.not_found).?);
    try testing.expectEqual(not_allowed, router.catchers.?.get(.method_not_allowed).?);
    try testing.expect(router.catchers.?.get(.internal_server_error) == null);
}

test "Router: setting a catcher twice replaces it" {
    var router = try newRouter();
    defer router.deinit();

    try router.setCatcher(.not_found, harness.textHandler("first"));
    const second = harness.textHandler("second");
    try router.setCatcher(.not_found, second);

    try testing.expectEqual(second, router.catchers.?.get(.not_found).?);
}

// ---------------------------------------------------------------------------
// Groups
// ---------------------------------------------------------------------------

test "Router: group returns a group carrying the prefix" {
    var router = try newRouter();
    defer router.deinit();

    var group = try router.group("/api");
    defer group.deinit();

    try testing.expectEqualStrings("/api", group.prefix);
    try testing.expectEqual(router, group.router);
}

test "Router: routes added through a group are visible on the router" {
    var router = try newRouter();
    defer router.deinit();

    var group = try router.group("/api");
    defer group.deinit();
    try group.get("/users", harness.textHandler("users"));

    try testing.expectEqualStrings("/api/users", (try router.getRoute(.GET, "/api/users")).path);
}
