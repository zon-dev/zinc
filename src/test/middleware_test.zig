const std = @import("std");
const zinc = @import("../zinc.zig");
const expect = std.testing.expect;

test "Middleware" {
    var router = zinc.Router.init(.{});

    // var signature: []const u8 = undefined;
    // signature = "";

    const mid1 = struct {
        fn testMiddle1(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Hello ", .{});
            try ctx.next();
        }
    }.testMiddle1;

    const mid2 = struct {
        fn testMiddle2(ctx: *zinc.Context) anyerror!void {
            try ctx.next();
            try ctx.text("World", .{});
        }
    }.testMiddle2;

    // add middleware to the route

    const handle = struct {
        fn anyHandle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("!", .{});
        }
    }.anyHandle;

    // create a route
    try router.get("/test", handle);

    try router.use(&.{ mid1, mid2 });

    try std.testing.expectEqual(1, router.getRoutes().items.len);
    try std.testing.expectEqual(3, router.getRoutes().items[0].handlers_chain.items.len);

    var ctx_get = try createContext(.GET, "/test");
    try router.handleContext(&ctx_get);

    try std.testing.expectEqual(.ok, ctx_get.response.status);
    // TODO
    // try std.testing.expectEqualStrings("Hello ! world", ctx_get.response.body.?[0.."Hello ! world".len]);

}

fn createContext(method: std.http.Method, target: []const u8) anyerror!zinc.Context {
    var req = zinc.Request.init(.{ .method = method, .target = target });
    var res = zinc.Response.init(.{});
    const ctx = zinc.Context.init(.{ .request = &req, .response = &res }).?;
    return ctx;
}
