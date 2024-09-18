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

fn createContext(allocator: std.mem.Allocator, method: std.http.Method, target: []const u8) anyerror!*zinc.Context {
    const req = try zinc.Request.init(.{ .allocator = allocator, .req = undefined, .method = method, .target = target });
    const res = try zinc.Response.init(.{ .allocator = allocator, .req = undefined, .res = undefined });
    return try zinc.Context.init(.{ .allocator = allocator, .request = req, .response = res });
}

test "RouterGroup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    // const allocator = std.testing.allocator;

    var router = try Router.init(.{ .allocator = allocator });
    defer router.deinit();

    const handle = struct {
        fn anyHandle(ctx: *Context) anyerror!void {
            try ctx.text("Hello Zinc!", .{});
        }
    }.anyHandle;

    var test_group = try router.group("/test");
    try test_group.get("/group", handle);

    var group2 = try router.group("/test2");
    try group2.get("/group2", handle);
    var group_user = try group2.group("/user");
    _ = try group_user.get("/login", handle);

    const routes = router.getRoutes();
    defer routes.deinit();

    try std.testing.expectEqual(3, routes.items.len);

    const route = try router.getRoute(.GET, "/test/group");
    try std.testing.expectEqualStrings("/test/group", route.path);

    const route_login = try router.getRoute(.GET, "/test2/user/login");
    try std.testing.expectEqualStrings("/test2/user/login", route_login.getPath());
}
