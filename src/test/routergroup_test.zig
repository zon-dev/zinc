//! Tests for `zinc.RouterGroup`, which prefixes a set of routes.
//!
//! A group holds an owned copy of its prefix and delegates registration to the
//! router with the prefix prepended. Nested groups compose by concatenation.
//!
//! Not covered, because they do not compile when referenced: `RouterGroup.use`
//! (passes a single handler where the router expects a slice), `getRoutes`
//! (declares a `std.ArrayList(Route)` return type the router never produces)
//! and `getRootTree` (calls a `getRoot` that does not exist). These are
//! reported separately rather than tested.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Router = zinc.Router;
const RouterGroup = zinc.RouterGroup;
const Route = zinc.Route;
const RouteError = Route.RouteError;

const harness = @import("harness.zig");

fn routeCount(router: *Router) usize {
    const routes = router.getRoutes();
    defer routes.deinit();
    return routes.items.len;
}

test "RouterGroup: carries its prefix and router" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var group = try router.group("/api");
    defer group.deinit();

    try testing.expectEqualStrings("/api", group.prefix);
    try testing.expectEqual(router, group.router);
    try testing.expect(group.root);
}

test "RouterGroup: the prefix is an owned copy" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var prefix = "/api".*;
    var group = try router.group(&prefix);
    defer group.deinit();

    prefix[1] = 'X';

    try testing.expectEqualStrings("/api", group.prefix);
}

test "RouterGroup: get registers a prefixed route" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var group = try router.group("/test");
    defer group.deinit();
    try group.get("/group", harness.textHandler("Hello Zinc!"));

    const route = try router.getRoute(.GET, "/test/group");
    try testing.expectEqualStrings("/test/group", route.path);
    try testing.expectEqualStrings("/test/group", route.getPath());
}

test "RouterGroup: nested groups concatenate prefixes" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    const handler = harness.textHandler("Hello Zinc!");

    var test_group = try router.group("/test");
    defer test_group.deinit();
    try test_group.get("/group", handler);

    var group2 = try router.group("/test2");
    defer group2.deinit();
    try group2.get("/group2", handler);

    var group_user = try group2.group("/user");
    defer group_user.deinit();
    try group_user.get("/login", handler);

    try testing.expectEqual(@as(usize, 3), routeCount(router));
    try testing.expectEqualStrings("/test/group", (try router.getRoute(.GET, "/test/group")).path);
    try testing.expectEqualStrings("/test2/group2", (try router.getRoute(.GET, "/test2/group2")).path);
    try testing.expectEqualStrings(
        "/test2/user/login",
        (try router.getRoute(.GET, "/test2/user/login")).getPath(),
    );
}

test "RouterGroup: three levels of nesting" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var api = try router.group("/api");
    defer api.deinit();
    var v1 = try api.group("/v1");
    defer v1.deinit();
    var users = try v1.group("/users");
    defer users.deinit();

    try users.get("/me", harness.textHandler("me"));

    try testing.expectEqualStrings("/api/v1/users/me", (try router.getRoute(.GET, "/api/v1/users/me")).path);
}

test "RouterGroup: every verb helper prefixes the path" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var group = try router.group("/api");
    defer group.deinit();

    const handler = harness.textHandler("ok");
    try group.get("/r", handler);
    try group.post("/r", handler);
    try group.put("/r", handler);
    try group.delete("/r", handler);
    try group.patch("/r", handler);
    try group.options("/r", handler);
    try group.head("/r", handler);
    try group.connect("/r", handler);
    try group.trace("/r", handler);

    const methods = [_]std.http.Method{
        .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS, .HEAD, .CONNECT, .TRACE,
    };
    for (methods) |method| {
        const route = try router.getRoute(method, "/api/r");
        try testing.expectEqual(method, route.method);
        try testing.expectEqualStrings("/api/r", route.path);
    }
}

test "RouterGroup: add registers a single method" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var group = try router.group("/api");
    defer group.deinit();
    try group.add(.PUT, "/item", harness.textHandler("put"));

    try testing.expectEqual(std.http.Method.PUT, (try router.getRoute(.PUT, "/api/item")).method);
}

test "RouterGroup: any registers every method" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var group = try router.group("/api");
    defer group.deinit();
    try group.any("/all", harness.textHandler("all"));

    const methods = [_]std.http.Method{
        .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS, .HEAD, .CONNECT, .TRACE,
    };
    for (methods) |method| {
        try testing.expectEqual(method, (try router.getRoute(method, "/api/all")).method);
    }
}

test "RouterGroup: addAny registers only the listed methods" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var group = try router.group("/api");
    defer group.deinit();
    try group.addAny(&.{ .GET, .DELETE }, "/some", harness.textHandler("some"));

    try testing.expectEqual(std.http.Method.GET, (try router.getRoute(.GET, "/api/some")).method);
    try testing.expectEqual(std.http.Method.DELETE, (try router.getRoute(.DELETE, "/api/some")).method);
    try testing.expectError(RouteError.MethodNotAllowed, router.getRoute(.POST, "/api/some"));
}

test "RouterGroup: an empty prefix leaves paths unchanged" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var group = try router.group("");
    defer group.deinit();
    try group.get("/plain", harness.textHandler("plain"));

    try testing.expectEqualStrings("/plain", (try router.getRoute(.GET, "/plain")).path);
}

test "RouterGroup: a route registered with an empty path lands on the prefix" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var group = try router.group("/api");
    defer group.deinit();
    try group.get("", harness.textHandler("index"));

    try testing.expectEqualStrings("/api", (try router.getRoute(.GET, "/api")).path);
}

test "RouterGroup: sibling groups stay independent" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var a = try router.group("/a");
    defer a.deinit();
    var b = try router.group("/b");
    defer b.deinit();

    try a.get("/x", harness.textHandler("ax"));
    try b.get("/x", harness.textHandler("bx"));

    try testing.expectEqualStrings("/a/x", (try router.getRoute(.GET, "/a/x")).path);
    try testing.expectEqualStrings("/b/x", (try router.getRoute(.GET, "/b/x")).path);
    try testing.expectError(RouteError.NotFound, router.getRoute(.GET, "/x"));
}

test "RouterGroup: a handler registered through a group runs" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    var group = try router.group("/api");
    defer group.deinit();
    try group.get("/hello", harness.textHandler("Hello from group"));

    var tc = try harness.newContext(testing.allocator, .{ .target = "/api/hello" });
    defer tc.deinit();

    try harness.runChain(tc.ctx, try router.getRoute(.GET, "/api/hello"));

    try harness.expectBody(tc.ctx, "Hello from group");
}

test "RouterGroup: router middleware applies to group routes" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    try router.use(&.{harness.tracingMiddleware("mw")});

    var group = try router.group("/api");
    defer group.deinit();
    try group.get("/traced", harness.tracingHandler("handler", "done"));

    var tc = try harness.newContext(testing.allocator, .{ .target = "/api/traced" });
    defer tc.deinit();

    harness.Trace.reset();
    try harness.runChain(tc.ctx, try router.getRoute(.GET, "/api/traced"));

    try harness.Trace.expectOrder(&.{ "mw:before", "handler", "mw:after" });
}
