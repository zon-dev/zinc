const std = @import("std");
const testing = std.testing;
const http = std.http;

const zinc = @import("../zinc.zig");
const Request = zinc.Request;
const Response = zinc.Response;
const Context = zinc.Context;

const Route = zinc.Route;
const Router = zinc.Router;
const RouteError = Route.RouteError;

fn createContext(method: std.http.Method, target: []const u8) anyerror!Context {
    const allocator = std.testing.allocator;

    var req = zinc.Request.init(.{ .method = method, .target = target, .allocator = allocator });
    var res = zinc.Response.init(.{ .allocator = allocator });
    const ctx = zinc.Context.init(.{ .request = &req, .response = &res, .allocator = allocator }).?;
    return ctx;
}

const TestServer = struct {
    server_thread: std.Thread,
    net_server: std.net.Server,

    fn destroy(self: *@This()) void {
        self.server_thread.join();
        self.net_server.deinit();
        std.testing.allocator.destroy(self);
    }

    fn port(self: @This()) u16 {
        return self.net_server.listen_address.in.getPort();
    }
};

fn createTestServer(S: type) !*TestServer {
    // if (std.builtin.single_threaded) return error.SkipZigTest;
    // if (builtin.zig_backend == .stage2_llvm and native_endian == .big) {
    //     // https://github.com/ziglang/zig/issues/13782
    //     return error.SkipZigTest;
    // }

    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    const test_server = try std.testing.allocator.create(TestServer);
    test_server.net_server = try address.listen(.{ .reuse_address = true });
    test_server.server_thread = try std.Thread.spawn(.{}, S.run, .{&test_server.net_server});
    return test_server;
}

// test "Router. Handle Request" {
//     var router = Router.init(.{});

//     const handle = struct {
//         fn anyHandle(ctx: *Context) anyerror!void {
//             try ctx.text("Hello Zinc!", .{});
//         }
//     }.anyHandle;
//     try router.get("/", handle);
//     try router.post("/", handle);

//     // GET Request.
//     var ctx_get = try createContext(.GET, "/");
//     try router.prepareContext(&ctx_get);
//     // TODO
//     // try testing.expectEqual(.ok, ctx_get.response.status);
//     try testing.expectEqualStrings("Hello Zinc!", ctx_get.response.body.?);
//     defer ctx_get.destroy();
//     std.debug.print("\r\n Done handle GET request test", .{});

//     // POST Request.
//     var ctx_post = try createContext(.POST, "/");
//     try router.prepareContext(&ctx_post);
//     // TODO
//     // try testing.expectEqual(.ok, ctx_post.response.status);
//     try testing.expectEqualStrings("Hello Zinc!", ctx_post.response.body.?);
//     defer ctx_post.destroy();
//     std.debug.print("\r\n Done handle POST request test", .{});

//     // Not found
//     var ctx_not_found = try createContext(.GET, "/not-found");
//     router.prepareContext(&ctx_not_found) catch |err| {
//         try testing.expect(err == RouteError.NotFound);
//     };
//     defer ctx_not_found.destroy();
//     std.debug.print("\r\n Done not found test", .{});

//     // Method not allowed
//     var ctx_not_allowed = try createContext(.PUT, "/");
//     router.prepareContext(&ctx_not_allowed) catch |err| {
//         try testing.expect(err == RouteError.MethodNotAllowed);
//     };
//     defer ctx_not_allowed.destroy();
//     std.debug.print("\r\n Done method not allowed test", .{});
// }

test "router, routeTree and router.getRoute" {
    var router = Router.init(.{});
    const handler = struct {
        fn anyHandle(ctx: *Context) anyerror!void {
            try ctx.text("Hello Zinc!", .{});
        }
    }.anyHandle;

    var static_route = Route.init(.{ .method = .GET, .path = "/static" });
    try static_route.handlers.append(handler);
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

    for (testCases) |tc| {
        const rTree_route = router.getRoute(tc.reqMethod, tc.reqPath) catch |err| {
            try testing.expect(err == (tc.expected catch |e| e));
            continue;
        };

        try testing.expectEqual(rTree_route.*, (try tc.expected));
    }
}
