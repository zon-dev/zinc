const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Request = zinc.Request;
const Response = zinc.Response;
const Context = zinc.Context;

const Route = zinc.Route;
const Router = zinc.Router;
const RouteError = Route.RouteError;

fn createContext(method: std.http.Method, target: []const u8) anyerror!Context {
    var req = zinc.Request.init(.{ .method = method, .target = target });
    var res = zinc.Response.init(.{});
    const ctx = zinc.Context.init(.{ .request = &req, .response = &res }).?;
    return ctx;
}

test "Handle Request" {
    var router = Router.init(.{});

    const handle = struct {
        fn anyHandle(ctx: *Context) anyerror!void {
            try ctx.setStatus(.ok);
            try ctx.setBody("Hello Zinc!");
        }
    }.anyHandle;
    try router.get("/", handle);
    try router.post("/", handle);

    // GET Request.
    var ctx_get = try createContext(.GET, "/");
    try router.handleContext(&ctx_get);
    // TODO
    // try testing.expectEqual(.ok, ctx_get.response.status);
    try testing.expectEqualStrings("Hello Zinc!", ctx_get.response.body.?);
    ctx_get.deinit();

    // POST Request.
    var ctx_post = try createContext(.POST, "/");
    try router.handleContext(&ctx_post);
    // TODO
    // try testing.expectEqual(.ok, ctx_post.response.status);
    try testing.expectEqualStrings("Hello Zinc!", ctx_post.response.body.?);
    ctx_post.deinit();

    // Not found
    var ctx_not_found = try createContext(.GET, "/not-found");
    router.handleContext(&ctx_not_found) catch |err| {
        try testing.expect(err == RouteError.NotFound);
    };
    ctx_not_found.deinit();

    // Method not allowed
    var ctx_not_allowed = try createContext(.PUT, "/");
    router.handleContext(&ctx_not_allowed) catch |err| {
        try testing.expect(err == RouteError.MethodNotAllowed);
    };
    ctx_not_allowed.deinit();
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
