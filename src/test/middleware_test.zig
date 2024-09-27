const std = @import("std");
const zinc = @import("../zinc.zig");
const expect = std.testing.expect;

const Context = zinc.Context;
const Request = zinc.Request;
const Response = zinc.Response;

test "Middleware" {
    const allocator = std.testing.allocator;
    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

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

    try router.use(&.{ mid1, mid2 });
    try router.get("/test", handle);

    const routes = router.getRoutes();
    defer routes.deinit();

    try std.testing.expectEqual(1, routes.items.len);
    try std.testing.expectEqual(3, routes.items[0].handlers.items.len);

    var ctx_get = try createContext(allocator, .GET, "/test");
    defer ctx_get.destroy();

    const route = try router.getRoute(ctx_get.request.method, ctx_get.request.target);
    ctx_get.handlers = route.handlers;
    try ctx_get.handlersProcess();
    try std.testing.expectEqual(.ok, ctx_get.response.status);
    try std.testing.expectEqual(3, ctx_get.handlers.items.len);
    try std.testing.expectEqualStrings("Hello world!", ctx_get.response.body orelse "");
}

fn createContext(allocator: std.mem.Allocator, method: std.http.Method, target: []const u8) anyerror!*Context {
    const req = try Request.init(.{ .allocator = allocator, .req = undefined, .method = method, .target = target });
    const res = try Response.init(.{ .allocator = allocator, .req = undefined, .res = undefined });
    return try Context.init(.{ .allocator = allocator, .request = req, .response = res });
}
