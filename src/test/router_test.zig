const std = @import("std");
const testing = std.testing;
const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const Router = zinc.Router;
const RouteError = Route.RouteError;

test "router" {
    const TestCase = struct {
        reqMethod: std.http.Method,
        reqPath: []const u8,
        expected: anyerror!Route,
    };

    var router = Router.init(.{});
    const static_route = Route.init(.{ .methods = &.{ .GET, .HEAD }, .path = "/static", .handler = undefined });
    try router.addRoute(static_route);

    const testCases = [_]TestCase{
        .{ .reqMethod = .GET, .reqPath = "/static", .expected = static_route },
        .{ .reqMethod = .GET, .reqPath = "/static/foo", .expected = static_route },
        .{ .reqMethod = .GET, .reqPath = "/static/foo/bar", .expected = static_route },

        .{ .reqMethod = .POST, .reqPath = "/static", .expected = RouteError.MethodNotAllowed },

        .{ .reqMethod = .GET, .reqPath = "/foo/static", .expected = RouteError.NotFound },
        .{ .reqMethod = .GET, .reqPath = "/foo/static/bar", .expected = RouteError.NotFound },
        .{ .reqMethod = .GET, .reqPath = "/foo/static/hello.css", .expected = RouteError.NotFound },
    };

    for (testCases, 0..) |tc, i| {
        const route_expected = router.matchRoute(tc.reqMethod, tc.reqPath) catch |err| {
            try testing.expect(err == (tc.expected catch |e| e));
            std.debug.print(" \r\n test1 case {d} passed, path: {s} ", .{ i, tc.reqPath });
            continue;
        };

        try testing.expectEqual(route_expected.*, (try tc.expected));
        std.debug.print(" \r\n test2 case {d} passed, path: {s} ", .{ i, tc.reqPath });
    }
}
