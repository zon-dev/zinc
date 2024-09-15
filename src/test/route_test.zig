const std = @import("std");
const testing = std.testing;
const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const RouteError = Route.RouteError;
const HandlerFn = zinc.HandlerFn;

test "route matching error" {
    const allocator = std.testing.allocator;

    const TestCase = struct {
        route: *Route,
        reqMethod: std.http.Method,
        reqPath: []const u8,
        expected: anyerror!*Route,
    };

    const foo_route = try Route.init(.{
        .method = .GET,
        .path = "/foo",
        .allocator = allocator,
        .handlers = std.ArrayList(HandlerFn).init(allocator),
    });

    defer foo_route.deinit();

    const testCases = [_]TestCase{
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/foo", .expected = foo_route },
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/foo=bar?", .expected = RouteError.NotFound },
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/foo=bar?", .expected = foo_route },
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
        const route = tc.route;
        _ = route;
        _ = i;
    }
}
