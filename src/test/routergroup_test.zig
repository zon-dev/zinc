//! `RouterGroup` prefixes a set of routes. Nested groups concatenate.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const RouteError = zinc.Route.RouteError;
const harness = @import("harness.zig");

test "RouterGroup: prefix is an owned copy and routes are visible on the router" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    var prefix = "/api".*;
    var group = try app.router.group(&prefix);
    defer group.deinit();
    prefix[1] = 'X';

    try testing.expectEqualStrings("/api", group.prefix);
    try testing.expectEqual(app.router, group.router);
    try testing.expect(group.root);

    try group.get("/users", harness.text("users"));
    try testing.expectEqualStrings("/api/users", (try app.router.getRoute(.GET, "/api/users")).path);
}

test "RouterGroup: nested groups concatenate prefixes" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    const handler = harness.text("Hello Zinc!");

    var test_group = try app.router.group("/test");
    defer test_group.deinit();
    try test_group.get("/group", handler);

    var group2 = try app.router.group("/test2");
    defer group2.deinit();
    try group2.get("/group2", handler);

    var group_user = try group2.group("/user");
    defer group_user.deinit();
    try group_user.get("/login", handler);

    var api = try app.router.group("/api");
    defer api.deinit();
    var v1 = try api.group("/v1");
    defer v1.deinit();
    var users = try v1.group("/users");
    defer users.deinit();
    try users.get("/me", harness.text("me"));

    try testing.expectEqual(@as(usize, 4), harness.routeCount(app.router));
    try testing.expectEqualStrings("/test/group", (try app.router.getRoute(.GET, "/test/group")).path);
    try testing.expectEqualStrings("/test2/group2", (try app.router.getRoute(.GET, "/test2/group2")).path);
    try testing.expectEqualStrings("/test2/user/login", (try app.router.getRoute(.GET, "/test2/user/login")).getPath());
    try testing.expectEqualStrings("/api/v1/users/me", (try app.router.getRoute(.GET, "/api/v1/users/me")).path);
}

test "RouterGroup: every verb helper prefixes the path" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    var group = try app.router.group("/api");
    defer group.deinit();

    const handler = harness.text("ok");
    try group.get("/r", handler);
    try group.post("/r", handler);
    try group.put("/r", handler);
    try group.delete("/r", handler);
    try group.patch("/r", handler);
    try group.options("/r", handler);
    try group.head("/r", handler);
    try group.connect("/r", handler);
    try group.trace("/r", handler);

    for (harness.methods) |method| {
        const route = try app.router.getRoute(method, "/api/r");
        try testing.expectEqual(method, route.method);
        try testing.expectEqualStrings("/api/r", route.path);
    }

    try group.add(.PUT, "/item", harness.text("put"));
    try testing.expectEqual(std.http.Method.PUT, (try app.router.getRoute(.PUT, "/api/item")).method);

    try group.any("/all", harness.text("all"));
    for (harness.methods) |method| {
        try testing.expectEqual(method, (try app.router.getRoute(method, "/api/all")).method);
    }

    try group.addAny(&.{ .GET, .DELETE }, "/some", harness.text("some"));
    try testing.expectEqual(std.http.Method.GET, (try app.router.getRoute(.GET, "/api/some")).method);
    try testing.expectEqual(std.http.Method.DELETE, (try app.router.getRoute(.DELETE, "/api/some")).method);
    try testing.expectError(RouteError.MethodNotAllowed, app.router.getRoute(.POST, "/api/some"));
}

test "RouterGroup: empty prefix, empty path, and sibling independence" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    var plain = try app.router.group("");
    defer plain.deinit();
    try plain.get("/plain", harness.text("plain"));
    try testing.expectEqualStrings("/plain", (try app.router.getRoute(.GET, "/plain")).path);

    var api = try app.router.group("/api");
    defer api.deinit();
    try api.get("", harness.text("index"));
    try testing.expectEqualStrings("/api", (try app.router.getRoute(.GET, "/api")).path);

    var a = try app.router.group("/a");
    defer a.deinit();
    var b = try app.router.group("/b");
    defer b.deinit();
    try a.get("/x", harness.text("ax"));
    try b.get("/x", harness.text("bx"));
    try testing.expectEqualStrings("/a/x", (try app.router.getRoute(.GET, "/a/x")).path);
    try testing.expectEqualStrings("/b/x", (try app.router.getRoute(.GET, "/b/x")).path);
    try testing.expectError(RouteError.NotFound, app.router.getRoute(.GET, "/x"));
}

test "RouterGroup: a handler registered through a group runs; router middleware applies" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    try app.router.use(&.{harness.tracingMiddleware("mw")});
    var group = try app.router.group("/api");
    defer group.deinit();
    try group.get("/hello", harness.text("Hello from group"));
    try group.get("/traced", harness.tracingHandler("handler", "done"));

    {
        var res = try app.get("/api/hello");
        defer res.deinit();
        try res.expectBody("Hello from group");
    }

    harness.Trace.reset();
    var res = try app.get("/api/traced");
    defer res.deinit();
    try harness.Trace.expectOrder(&.{ "mw:before", "handler", "mw:after" });
}
