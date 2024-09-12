const std = @import("std");
const zinc = @import("../zinc.zig");
const expect = std.testing.expect;

test "Middleware" {
    var router = zinc.Router.init(.{});
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
    try std.testing.expectEqual(1, router.getRoutes().items.len);
    try std.testing.expectEqual(3, router.getRoutes().items[0].handlers.items.len);

    var ctx_get = try createContext(.GET, "/test");
    defer ctx_get.destroy();

    try router.prepareContext(&ctx_get);

    try std.testing.expectEqual(.ok, ctx_get.response.status);
    try std.testing.expectEqual(3, ctx_get.handlers.items.len);

    // TODO
    // try std.testing.expectEqualStrings("Hello world!", ctx_get.response.body orelse "");
}

fn createContext(method: std.http.Method, target: []const u8) anyerror!zinc.Context {
    const allocator = std.testing.allocator;
    var req = zinc.Request.init(.{ .method = method, .target = target, .allocator = allocator });
    var res = zinc.Response.init(.{ .allocator = allocator });
    const ctx = zinc.Context.init(.{ .request = &req, .response = &res, .allocator = allocator }).?;
    return ctx;
}
