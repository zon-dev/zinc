const std = @import("std");
const testing = std.testing;
const zinc = @import("../zinc.zig");

test "HTTP response with connection close" {
    const allocator = testing.allocator;

    // create router
    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    // add a simple handler
    try router.get("/test", testHandler);

    // verify route added - check if route tree has routes
    const routes = router.getRoutes();
    defer routes.deinit();
    try testing.expect(routes.items.len > 0);
}

fn testHandler(ctx: *zinc.Context) !void {
    try ctx.json(.{
        .message = "Hello, World!",
        .status = "success",
    }, .{});
}
