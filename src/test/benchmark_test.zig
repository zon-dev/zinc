const std = @import("std");
const zinc = @import("../zinc.zig");
const expect = std.testing.expect;
const posix = std.posix;

test "benchmark: plaintext performance" {
    const allocator = std.testing.allocator;

    // Initialize server with high concurrency settings
    var z = try zinc.init(.{
        .port = 0, // Use random port for testing
        .allocator = allocator,
        .num_threads = 4, // Use 4 threads for testing
        .read_buffer_len = 10 * 1024,
        .stack_size = 10 * 1024 * 1024,
        .max_conn = 10000,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/plaintext", plaintext);

    // Start server in background
    const server_thread = try std.Thread.spawn(.{}, runServer, .{&z});
    defer {
        z.shutdown(0);
        server_thread.join();
    }

    // Wait for server to start
    std.time.sleep(100 * std.time.ns_per_ms);

    // Get server address
    const address = z.getAddress();

    // Run benchmark: send requests and measure throughput
    const num_requests = 20000;
    const num_threads = 8;
    const requests_per_thread = num_requests / num_threads;

    var threads: [num_threads]std.Thread = undefined;
    var results: [num_threads]BenchmarkResult = undefined;

    const start_time = std.time.nanoTimestamp();

    // Spawn worker threads
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, benchmarkWorker, .{
            &results[i],
            address,
            requests_per_thread,
        });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    const end_time = std.time.nanoTimestamp();
    const total_time_ns = end_time - start_time;
    const total_time_sec = @as(f64, @floatFromInt(total_time_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));

    // Calculate total results
    var total_success: usize = 0;
    var total_errors: usize = 0;
    for (results) |result| {
        total_success += result.success;
        total_errors += result.errors;
    }

    const requests_per_sec = @as(f64, @floatFromInt(total_success)) / total_time_sec;
    const error_rate = @as(f64, @floatFromInt(total_errors)) / @as(f64, @floatFromInt(num_requests)) * 100.0;

    std.debug.print("\n=== Benchmark Results ===\n", .{});
    std.debug.print("Total requests: {}\n", .{num_requests});
    std.debug.print("Successful: {}\n", .{total_success});
    std.debug.print("Errors: {}\n", .{total_errors});
    std.debug.print("Error rate: {d:.2f}%\n", .{error_rate});
    std.debug.print("Time: {d:.2f}s\n", .{total_time_sec});
    std.debug.print("Requests/sec: {d:.2f}\n", .{requests_per_sec});
    std.debug.print("=======================\n\n", .{});

    // Performance requirements:
    // - Should handle at least 10,000 requests/sec
    // - Error rate should be < 1%
    try expect(error_rate < 1.0); // Less than 1% error rate
    try expect(requests_per_sec >= 10000.0); // At least 10k req/s
}

const BenchmarkResult = struct {
    success: usize = 0,
    errors: usize = 0,
};

fn benchmarkWorker(result: *BenchmarkResult, address: std.Io.net.IpAddress, num_requests: usize) void {
    result.* = .{};

    for (0..num_requests) |_| {
        sendRequest(address) catch {
            result.errors += 1;
            continue;
        };
        result.success += 1;
    }
}

fn sendRequest(address: std.Io.net.IpAddress) !void {
    // Convert IpAddress to sockaddr
    var sockaddr: posix.sockaddr = undefined;
    var socklen: posix.socklen_t = undefined;
    var family: posix.sa_family_t = undefined;

    switch (address) {
        .ip4 => |ip4| {
            var sa: posix.sockaddr.in = undefined;
            sa.family = posix.AF.INET;
            sa.port = std.mem.nativeToBig(u16, ip4.port);
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

    // Connect
    try posix.connect(sockfd, &sockaddr, socklen);

    const request = "GET /plaintext HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    _ = try posix.write(sockfd, request);

    // Read complete response - read until connection closes
    // This ensures we wait for the full response, similar to real-world usage
    var buffer: [1024]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < buffer.len) {
        const bytes_read = try posix.read(sockfd, buffer[total_read..]);
        if (bytes_read == 0) break; // Connection closed
        total_read += bytes_read;
    }
    
    // Verify we received a response
    if (total_read == 0) {
        return error.NoResponse;
    }
    
    // Verify it's a valid HTTP response (starts with "HTTP/")
    if (total_read < 5 or !std.mem.eql(u8, buffer[0..5], "HTTP/")) {
        return error.InvalidResponse;
    }
    
    // Verify status code is 200 (look for "200" after "HTTP/1.x ")
    // HTTP/1.1 200 OK\r\n
    const status_line_end = std.mem.indexOf(u8, buffer[0..total_read], "\r\n") orelse return error.InvalidResponse;
    const status_line = buffer[0..status_line_end];
    if (std.mem.indexOf(u8, status_line, " 200 ") == null) {
        return error.BadStatusCode;
    }
}

fn plaintext(ctx: *zinc.Context) anyerror!void {
    try ctx.text("Hello, zinc!", .{});
}

fn runServer(engine: *zinc.Engine) void {
    engine.run() catch |err| {
        std.log.err("Server error: {}", .{err});
    };
}
