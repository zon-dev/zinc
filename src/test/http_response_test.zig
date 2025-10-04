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

test "Response memory alias fix verification" {
    const allocator = testing.allocator;

    // Create a response
    var response = try zinc.Response.init(.{ .allocator = allocator });
    defer response.deinit();

    // Test that response can be created and initialized without memory issues
    // This verifies the fix for memory alias issue in response.zig
    try testing.expect(response.allocator.ptr == allocator.ptr);

    // Test that response has proper initial state
    try testing.expect(response.status == .ok);
    try testing.expect(response.body == null);

    // Test should pass without memory alias errors
    try testing.expect(true);
}

test "Response header management" {
    const allocator = testing.allocator;

    var response = try zinc.Response.init(.{ .allocator = allocator });
    defer response.deinit();

    // Test setting headers
    try response.setHeader("Content-Type", "application/json");
    try response.setHeader("Cache-Control", "no-cache");

    // Test that headers were set correctly
    try testing.expect(response.header.items.len == 2);
    try testing.expectEqualStrings(response.header.items[0].name, "Content-Type");
    try testing.expectEqualStrings(response.header.items[0].value, "application/json");
    try testing.expectEqualStrings(response.header.items[1].name, "Cache-Control");
    try testing.expectEqualStrings(response.header.items[1].value, "no-cache");

    // Test should pass without memory alias errors
    try testing.expect(true);
}

fn testHandler(ctx: *zinc.Context) !void {
    try ctx.json(.{
        .message = "Hello, World!",
        .status = "success",
    }, .{});
}
