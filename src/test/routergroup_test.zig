const std = @import("std");
const testing = std.testing;
const http = std.http;

const zinc = @import("../zinc.zig");
const HandlerFn = zinc.HandlerFn;
const Request = zinc.Request;
const Response = zinc.Response;
const Context = zinc.Context;

const Route = zinc.Route;
const Router = zinc.Router;
const RouterGroup = zinc.RouterGroup;
const RouteError = Route.RouteError;

fn createContext(allocator: std.mem.Allocator, method: std.http.Method, target: []const u8) anyerror!*Context {
    var req = zinc.Request.init(.{ .method = method, .target = target, .allocator = allocator });
    var res = zinc.Response.init(.{ .allocator = allocator });
    const ctx = try zinc.Context.init(.{ .request = &req, .response = &res, .allocator = allocator });
    return ctx;
}

test "RouterGroup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = true,
    }){};
    const allocator = gpa.allocator();
    // const allocator = std.testing.allocator;

    var router = try Router.init(.{ .allocator = allocator });

    defer router.deinit();

    const handle = struct {
        fn anyHandle(ctx: *Context) anyerror!void {
            try ctx.text("Hello Zinc!", .{});
        }
    }.anyHandle;

    const group_path = "/test";
    var router_group = try router.group(group_path);
    defer router_group.deinit();

    try router_group.get("/group", handle);

    const routes = router.getRoutes();
    defer routes.deinit();

    try std.testing.expectEqual(1, routes.items.len);

    const route = try router.getRoute(.GET, "/test/group");
    try std.testing.expectEqualStrings("/test/group", route.path);

    // try router.post("/", handle);

    // GET Request.
    var ctx_get = try createContext(allocator, .GET, "/");
    try ctx_get.handlers.appendSlice(route.handlers.items);
    // TODO
    // try ctx_get.handlersProcess();
    // try testing.expectEqual(.ok, ctx_get.response.status);
    // try testing.expectEqualStrings("Hello Zinc!", ctx_get.response.body.?);
    // defer ctx_get.destroy();
    // std.debug.print("\r\n Done handle GET request test", .{});

    // POST Request.
    // var ctx_post = try createContext(.POST, "/");
    // TODO
    // try router.prepareContext(ctx_post);
    // try testing.expectEqual(.ok, ctx_post.response.status);
    // try testing.expectEqualStrings("Hello Zinc!", ctx_post.response.body.?);
    // defer ctx_post.destroy();
    // std.debug.print("\r\n Done handle POST request test", .{});

    // // Not found
    // var ctx_not_found = try createContext(.GET, "/not-found");
    // router.prepareContext(ctx_not_found) catch |err| {
    //     try testing.expect(err == RouteError.NotFound);
    // };
    // defer ctx_not_found.destroy();

    // // Method not allowed
    // var ctx_not_allowed = try createContext(.PUT, "/");
    // router.prepareContext(ctx_not_allowed) catch |err| {
    //     try testing.expect(err == RouteError.MethodNotAllowed);
    // };
    // defer ctx_not_allowed.destroy();
}
