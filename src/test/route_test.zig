const std = @import("std");
const testing = std.testing;
const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const RouteError = Route.RouteError;

test "route matching error" {
    const TestCase = struct {
        route: Route,
        reqMethod: std.http.Method,
        reqPath: []const u8,
        expected: anyerror!Route,
    };

    const foo_route = Route.init(.{ .methods = &.{.GET}, .path = "/foo", .handler = undefined });
    const testCases = [_]TestCase{
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/foo", .expected = foo_route },
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/foo=bar?", .expected = RouteError.NotFound },
        // .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/foo=bar?", .expected = foo_route },
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/foo#", .expected = foo_route },
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/foo?code=123", .expected = foo_route },
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/foo?code=123&state=xyz", .expected = foo_route },

        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/?foo=bar?", .expected = RouteError.NotFound },
        .{ .route = foo_route, .reqMethod = .POST, .reqPath = "/foo", .expected = RouteError.MethodNotAllowed },
        .{ .route = foo_route, .reqMethod = .POST, .reqPath = "foo", .expected = RouteError.NotFound },
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/bar", .expected = RouteError.NotFound },
        .{ .route = foo_route, .reqMethod = .POST, .reqPath = "/bar", .expected = RouteError.NotFound },
    };

    for (testCases, 0..) |tc, i| {
        var route = tc.route;
        const route_expected = route.match(tc.reqMethod, tc.reqPath) catch |err| {
            try testing.expect(err == (tc.expected catch |e| e));
            std.debug.print(" \r\n route test1 case {d} passed, path: {s} ", .{ i, tc.reqPath });
            continue;
        };

        try testing.expectEqual(route_expected.*, (try tc.expected));
        std.debug.print(" \r\n route test2 case {d} passed, path: {s} ", .{ i, tc.reqPath });
    }
}
