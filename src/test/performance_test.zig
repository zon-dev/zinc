const std = @import("std");
const zinc = @import("../zinc.zig");
const Io = std.Io;
const posix = std.posix;

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

    // Give the server time to start - use posix.nanosleep
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);

    const port = engine.getPort();
    const address = try Io.net.IpAddress.parse("127.0.0.1", port);

    // Benchmark: Send 1000 requests
    const num_requests = 1000;
    var timer = try std.time.Timer.start();

    for (0..num_requests) |_| {
        // Create socket and connect
        // Convert IpAddress to sockaddr
        var sockaddr: posix.sockaddr = undefined;
        var socklen: posix.socklen_t = undefined;
        var family: posix.sa_family_t = undefined;

        switch (address) {
            .ip4 => |ip4| {
                var sa: posix.sockaddr.in = undefined;
                sa.family = posix.AF.INET;
                sa.port = std.mem.nativeToBig(u16, ip4.port);
                // ip4.bytes stores address as [a, b, c, d] for a.b.c.d
                // sockaddr.in.addr needs network byte order (big-endian) u32
                const addr_u32 = (@as(u32, ip4.bytes[0]) << 24) |
                    (@as(u32, ip4.bytes[1]) << 16) |
                    (@as(u32, ip4.bytes[2]) << 8) |
                    (@as(u32, ip4.bytes[3]));
                sa.addr = @bitCast(std.mem.nativeToBig(u32, addr_u32));
                sockaddr = @bitCast(sa);
                socklen = @sizeOf(posix.sockaddr.in);
                family = posix.AF.INET;
            },
            .ip6 => |ip6| {
                var sa: posix.sockaddr.in6 = undefined;
                sa.family = posix.AF.INET6;
                sa.port = std.mem.nativeToBig(u16, ip6.port);
                @memcpy(&sa.addr, &ip6.bytes);
                sockaddr = @bitCast(sa);
                socklen = @sizeOf(posix.sockaddr.in6);
                family = posix.AF.INET6;
            },
        }

        const sockfd = try posix.socket(family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
        defer posix.close(sockfd);

        // Set socket to non-blocking for connect
        const flags = try posix.fcntl(sockfd, posix.F.GETFL, 0);
        _ = try posix.fcntl(sockfd, posix.F.SETFL, flags | posix.O.NONBLOCK);

        // Connect with retry for non-blocking socket
        while (true) {
            posix.connect(sockfd, &sockaddr, socklen) catch |err| switch (err) {
                error.WouldBlock => {
                    // Wait a bit and retry
                    std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            break;
        }

        const request = "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        _ = try posix.write(sockfd, request);

        // Read response - read until connection closes
        var buffer: [1024]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < buffer.len) {
            const bytes_read = posix.read(sockfd, buffer[total_read..]) catch |err| switch (err) {
                error.WouldBlock => {
                    // Non-blocking socket, wait a bit and retry
                    std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
                    continue;
                },
                else => break,
            };
            if (bytes_read == 0) break; // Connection closed
            total_read += bytes_read;
        }
    }

    const elapsed = timer.read();
    const requests_per_second = @as(f64, @floatFromInt(num_requests)) / (@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(std.time.ns_per_s)));

    try std.testing.expect(requests_per_second > 100000);

    // Shutdown server and wait for thread to finish
    engine.shutdown(0);
    // Give server time to stop
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
    // Join with timeout - if thread doesn't finish, we'll continue anyway
    server_thread.join();
}
