const std = @import("std");
const zinc = @import("../zinc.zig");
const expect = std.testing.expect;

test "Middleware" {
    // const allocator = std.testing.allocator;
    // var router = zinc.Router.init(.{ .allocator = allocator });
    var router = zinc.Router.init(.{});
    // defer router.deinit();

    const mid1 = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Hello ", .{});
            try ctx.next();
        }
    }.middle;

    const mid2 = struct {
        fn middle(ctx: *zinc.Context) anyerror!void {
            try ctx.next();
            try ctx.text("!", .{});
        }
    }.middle;

    const handle = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("world", .{});
        }
    }.anyHandle;

    // create a route
    try router.get("/test", handle);

    try router.use(&.{ mid1, mid2 });
    const routes = router.getRoutes();

    try std.testing.expectEqual(1, routes.items.len);
    try std.testing.expectEqual(3, routes.items[0].handlers.items.len);

    var ctx_get = try createContext(.GET, "/test");
    defer ctx_get.destroy();

    const route = try router.getRoute(ctx_get.request.method, ctx_get.request.target);
    ctx_get.handlers = route.handlers;

    // TODO
    // try ctx_get.handlersProcess();

    try std.testing.expectEqual(.ok, ctx_get.response.status);
    try std.testing.expectEqual(3, ctx_get.handlers.items.len);

    // // TODO
    // try std.testing.expectEqualStrings("Hello world!", ctx_get.response.body orelse "");
}

fn createContext(method: std.http.Method, target: []const u8) anyerror!zinc.Context {
    var req = zinc.Request.init(.{ .method = method, .target = target });
    var res = zinc.Response.init(.{});
    return zinc.Context.init(.{ .request = &req, .response = &res }).?;
}
