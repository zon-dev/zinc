const std = @import("std");
const testing = std.testing;
const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const Router = zinc.Router;
const RouteError = Route.RouteError;

test "router" {
    var router = Router.init(.{});
    const static_route = Route.init(.{ .method = .GET, .path = "/static", .allocator = std.heap.page_allocator });
    try router.addRoute(static_route);

    const TestCase = struct {
        reqMethod: std.http.Method,
        reqPath: []const u8,
        expected: anyerror!Route,
    };
    const testCases = [_]TestCase{
        .{ .reqMethod = .GET, .reqPath = "/static", .expected = static_route },
        .{ .reqMethod = .GET, .reqPath = "/static/foo", .expected = static_route },
        .{ .reqMethod = .GET, .reqPath = "/static/foo/bar", .expected = static_route },
        .{ .reqMethod = .GET, .reqPath = "/static?code=123", .expected = static_route },
        .{ .reqMethod = .GET, .reqPath = "/static?code=123&state=xyz#foo", .expected = static_route },

        .{ .reqMethod = .POST, .reqPath = "/static", .expected = RouteError.MethodNotAllowed },

        .{ .reqMethod = .GET, .reqPath = "/foo/static", .expected = RouteError.NotFound },
        .{ .reqMethod = .GET, .reqPath = "/foo/static/bar", .expected = RouteError.NotFound },
        .{ .reqMethod = .GET, .reqPath = "/foo/static/hello.css", .expected = RouteError.NotFound },
    };

    for (testCases, 0..) |tc, i| {
        std.debug.print(" \r\n test case {d}, path: {s} ", .{ i, tc.reqPath });
        const route_expected = router.matchRoute(tc.reqMethod, tc.reqPath) catch |err| {
            try testing.expect(err == (tc.expected catch |e| e));
            // std.debug.print(" \r\n test1 case {d} passed, path: {s} ", .{ i, tc.reqPath });
            continue;
        };

        try testing.expectEqual(route_expected.*, (try tc.expected));
        // std.debug.print(" \r\n test2 case {d} passed, path: {s} ", .{ i, tc.reqPath });
    }
}

test "routeTree" {
    var router = Router.init(.{ .allocator = std.heap.page_allocator });
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
        // .{ .reqMethod = .GET, .reqPath = "/foo/static/hello.css", .expected = RouteError.NotFound },
    };

    for (testCases, 0..) |tc, i| {
        std.debug.print(" \r\n routeTree test case {d}, path: {s} \r\n", .{ i, tc.reqPath });

        const rTree = router.getRouteTree(tc.reqPath) catch |err| {
            std.debug.print(" \r\n 111 routeTree test case {d} passed, path: {s} ", .{ i, tc.reqPath });

            try testing.expect(err == (tc.expected catch |e| e));
            continue;
        };

        _ = rTree.route;
        std.debug.print(" \r\n 222 routeTree test case {d} passed, path: {s} ", .{ i, tc.reqPath });

        // // // const route = router.getRoute(tc.reqMethod, tc.reqPath) catch |err| {
        // // //     // std.debug.print(" \r\n routeTree test case {d} failed, err: {any} ", .{ i, err });
        // // //     try testing.expect(err == (tc.expected catch |e| e));
        // // //     continue;
        // // // };
        // std.debug.print(" \r\n routeTree test case {d} passed, path: {any}\r\n", .{ i, router.routes.items[0] });
        // try testing.expectEqual(route.*, (try tc.expected));
        // std.debug.print(" \r\n routeTree test case {d} passed, path: {s} ", .{ i, tc.reqPath });
    }
}
