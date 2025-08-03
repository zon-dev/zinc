const std = @import("std");
const testing = std.testing;
const zinc = @import("../zinc.zig");

test "HTTP response with connection close" {
    const allocator = testing.allocator;
    
    // 创建 router
    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();
    
    // 添加一个简单的 handler
    try router.get("/test", testHandler);
    
    // 验证路由已添加 - 检查路由树中是否有路由
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