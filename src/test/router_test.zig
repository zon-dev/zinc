const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Request = zinc.Request;
const Response = zinc.Response;
const Context = zinc.Context;

const Route = zinc.Route;
const Router = zinc.Router;
const RouteError = Route.RouteError;

test "root page" {
    var router = Router.init(.{});

    const handle = struct {
        fn anyHandle(ctx: *Context) anyerror!void {
            try ctx.setStatus(.ok);
            try ctx.setBody("Hello Zinc!");
        }
    }.anyHandle;
    try router.get("/", handle);
    try router.post("/", handle);

    var req = zinc.Request.init(.{ .method = .GET, .target = "/" });
    var res = zinc.Response.init(.{});
    var ctx = zinc.Context.init(.{ .request = &req, .response = &res }).?;
    _ = try router.handleContext(&ctx);

    // GET Request.
    try testing.expectEqual(.ok, ctx.response.status);
    try testing.expectEqualStrings("Hello Zinc!", ctx.response.body);

    var req_post = zinc.Request.init(.{ .method = .POST, .target = "/" });
    var res_post = zinc.Response.init(.{});
    var ctx_post = zinc.Context.init(.{ .request = &req_post, .response = &res_post }).?;
    _ = try router.handleContext(&ctx_post);

    // POST Request.
    try testing.expectEqual(.ok, ctx_post.response.status);
    try testing.expectEqualStrings("Hello Zinc!", ctx_post.response.body);

    // Not found
    var req_not_found = zinc.Request.init(.{ .method = .GET, .target = "/not-found" });
    var res_not_found = zinc.Response.init(.{});
    var ctx_not_found = zinc.Context.init(.{ .request = &req_not_found, .response = &res_not_found }).?;
    router.handleContext(&ctx_not_found) catch |err| {
        try testing.expect(err == RouteError.NotFound);
    };

    // Method not allowed
    var req_not_allowed = zinc.Request.init(.{ .method = .PUT, .target = "/" });
    var res_not_allowed = zinc.Response.init(.{});
    var ctx_not_allowed = zinc.Context.init(.{ .request = &req_not_allowed, .response = &res_not_allowed }).?;
    router.handleContext(&ctx_not_allowed) catch |err| {
        try testing.expect(err == RouteError.MethodNotAllowed);
    };
}

test "router, routeTree and router.getRoute" {
    var router = Router.init(.{});
    const static_route = Route.init(.{ .method = .GET, .path = "/static" });
    try router.addRoute(static_route);

    const TestCase = struct {
        reqMethod: std.http.Method,
        reqPath: []const u8,
        expected: anyerror!Route,
    };
    const testCases = [_]TestCase{
        .{ .reqMethod = .GET, .reqPath = "/static", .expected = static_route },
        .{ .reqMethod = .GET, .reqPath = "/static?code=123", .expected = static_route },
        .{ .reqMethod = .GET, .reqPath = "/static?code=123&state=xyz#foo", .expected = static_route },

        .{ .reqMethod = .POST, .reqPath = "/static", .expected = RouteError.MethodNotAllowed },
        .{ .reqMethod = .GET, .reqPath = "/static/foo", .expected = RouteError.NotFound },
        .{ .reqMethod = .GET, .reqPath = "/static/foo/bar", .expected = RouteError.NotFound },
        .{ .reqMethod = .GET, .reqPath = "/foo/static", .expected = RouteError.NotFound },
        .{ .reqMethod = .GET, .reqPath = "/foo/static/bar", .expected = RouteError.NotFound },
        .{ .reqMethod = .GET, .reqPath = "/foo/static/hello.css", .expected = RouteError.NotFound },
    };

    for (testCases, 0..) |tc, i| {
        std.debug.print(" \r\n routeTree test case {d}, path: {s}", .{ i, tc.reqPath });
        const rTree_route = router.getRoute(tc.reqMethod, tc.reqPath) catch |err| {
            try testing.expect(err == (tc.expected catch |e| e));
            continue;
        };

        try testing.expectEqual(rTree_route.*, (try tc.expected));
    }
}
