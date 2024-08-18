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
        expected: anyerror,
    };

    const foo_route = Route.init(.{ .methods = &.{.GET}, .path = "/foo", .handler = undefined });
    const testCases = [_]TestCase{
        .{ .route = foo_route, .reqMethod = .POST, .reqPath = "/foo", .expected = RouteError.MethodNotAllowed },
        .{ .route = foo_route, .reqMethod = .POST, .reqPath = "foo", .expected = RouteError.NotFound },
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/bar", .expected = RouteError.NotFound },
        .{ .route = foo_route, .reqMethod = .POST, .reqPath = "/bar", .expected = RouteError.NotFound },
    };

    for (testCases) |tc| {
        var route = tc.route;
        _ = route.match(tc.reqMethod, tc.reqPath) catch |err| {
            try testing.expect(err == tc.expected);
        };
    }
}
