const std = @import("std");
const zinc = @import("../zinc.zig");

test "aio basic engine initialization" {
    var engine = try zinc.Engine.init(.{
        .port = 0, // Use random port
        .force_nonblocking = true,
        .num_threads = 1, // Use single thread for testing
    });
    defer engine.deinit();

    try std.testing.expect(engine.getPort() > 0);
    try std.testing.expect(engine.num_threads == 1);
}

test "aio default configuration" {
    var engine = try zinc.Engine.default();
    defer engine.deinit();

    try std.testing.expect(engine.getPort() > 0);
    try std.testing.expect(engine.num_threads == 32); // Updated default thread count
    try std.testing.expect(engine.read_buffer_len == 32768); // Updated default buffer size
}

test "aio custom configuration" {
    var engine = try zinc.Engine.init(.{
        .addr = "127.0.0.1",
        .port = 0,
        .allocator = std.testing.allocator,
        .num_threads = 2,
        .read_buffer_len = 8192,
        .header_buffer_len = 2048,
        .body_buffer_len = 16384,
        .stack_size = 1048576, // 1MB
    });
    defer engine.deinit();

    try std.testing.expect(engine.num_threads == 2);
    try std.testing.expect(engine.read_buffer_len == 8192);
    try std.testing.expect(engine.header_buffer_len == 2048);
    try std.testing.expect(engine.body_buffer_len == 16384);
}

test "aio engine shutdown" {
    var engine = try zinc.Engine.init(.{
        .port = 0,
        .force_nonblocking = true,
        .num_threads = 1,
    });

    // Test shutdown without running
    engine.shutdown(1000000); // 1ms timeout

    // Should still be able to deinit
    engine.deinit();
}
