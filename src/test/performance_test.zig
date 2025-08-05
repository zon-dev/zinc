const std = @import("std");
const zinc = @import("../zinc.zig");

test "performance benchmark" {
    var engine = try zinc.Engine.init(.{
        .port = 0,
        .num_threads = 16,
        .read_buffer_len = 16384,
        .header_buffer_len = 2048,
        .body_buffer_len = 16384,
    });
    defer engine.deinit();

    // Add a simple route
    try engine.getRouter().get("/test", struct {
        fn handler(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Hello, World!", .{});
        }
    }.handler);

    // Start the server in a separate thread
    const server_thread = try std.Thread.spawn(.{}, zinc.Engine.run, .{engine});
    defer server_thread.join();

    // Give the server time to start
    std.time.sleep(100 * std.time.ns_per_ms);

    const port = engine.getPort();
    const address = try std.net.Address.parseIp("127.0.0.1", port);

    // Benchmark: Send 1000 requests
    const num_requests = 1000;
    var timer = try std.time.Timer.start();

    for (0..num_requests) |_| {
        var stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();

        const request = "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        try stream.writeAll(request);

        // Read response
        var buffer: [1024]u8 = undefined;
        _ = try stream.reader().read(&buffer);
    }

    const elapsed = timer.read();
    const requests_per_second = @as(f64, @floatFromInt(num_requests)) / (@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(std.time.ns_per_s)));

    std.debug.print("Performance: {d:.0} requests/second\n", .{requests_per_second});

    // Expect at least 1000 requests per second
    try std.testing.expect(requests_per_second > 1000);
}
