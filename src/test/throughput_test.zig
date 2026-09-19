//! Keep-alive plaintext throughput.
//!
//! `performance_test.zig` gates *latency-bound* paths: every request there opens
//! a fresh connection, so its numbers are dominated by connect + accept.
//! This file measures the workload a load generator actually runs — connections
//! held open, one request per round trip, Content-Length framed.
//!
//! `baseline_rps` is zinc's own pre-optimization number on this same workload
//! (loopback, keep-alive, plaintext). It is not a comparison against other
//! frameworks. The regression gate is `floor()`, not the baseline.
//!
//! Names are prefixed `perf:` so `zig build perf` picks them up.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const compat = @import("../zinc/posix_compat.zig");
const harness = @import("harness.zig");

const is_debug = builtin.mode == .debug;

/// Zinc keep-alive plaintext throughput recorded before inline handlers and
/// send-now. Same loopback / Content-Length / keep-alive workload as this file.
const baseline_rps: f64 = 34_892;

/// Hard regression gate for concurrent keep-alive in ReleaseFast.
const min_rps_release: f64 = 10_000;

fn printSummary(measured_rps: f64) void {
    const ratio = measured_rps / @max(baseline_rps, 1);
    std.debug.print("\n  keep-alive plaintext [{s}]\n", .{@tagName(builtin.mode)});
    std.debug.print("  this run: {d:.0} req/s\n", .{measured_rps});
    std.debug.print("  baseline: {d:.0} req/s ({d:.2}x)\n", .{ baseline_rps, ratio });
}

fn stdIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs() i96 {
    return std.Io.Clock.now(.awake, stdIo()).nanoseconds;
}

fn sleepMs(ms: i64) void {
    stdIo().sleep(.fromMilliseconds(ms), .awake) catch {};
}

const stall_timeout_us: i32 = 50_000;

fn windowMs() i64 {
    return if (is_debug) 400 else 1000;
}

fn floor(debug_min: f64, release_min: f64) f64 {
    return if (is_debug) debug_min else release_min;
}

fn rps(count: usize, elapsed_ns: i96) f64 {
    const ns: f64 = @floatFromInt(@max(elapsed_ns, 1));
    return @as(f64, @floatFromInt(count)) / (ns / 1e9);
}

fn loopback(port: u16) std.posix.sockaddr.in {
    var sa: std.posix.sockaddr.in = undefined;
    sa.family = std.posix.AF.INET;
    sa.port = std.mem.nativeToBig(u16, port);
    sa.addr = std.mem.nativeToBig(u32, 0x7f000001);
    return sa;
}

fn connectPort(port: u16) !compat.socket_t {
    const sa = loopback(port);
    const sockaddr: *const std.posix.sockaddr = @ptrCast(&sa);
    var last_err: ?compat.ConnectError = null;
    for (0..80) |_| {
        const fd = try compat.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            std.posix.IPPROTO.TCP,
        );
        if (compat.connect(fd, sockaddr, @sizeOf(std.posix.sockaddr.in))) {
            const tv = std.posix.timeval{ .sec = 0, .usec = stall_timeout_us };
            std.posix.setsockopt(
                fd,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVTIMEO,
                std.mem.asBytes(&tv),
            ) catch {};
            const one: c_int = 1;
            std.posix.setsockopt(
                fd,
                std.posix.IPPROTO.TCP,
                std.posix.TCP.NODELAY,
                std.mem.asBytes(&one),
            ) catch {};
            return fd;
        } else |err| {
            compat.close(fd);
            switch (err) {
                error.ConnectionRefused => {
                    last_err = err;
                    sleepMs(5);
                    continue;
                },
                else => return err,
            }
        }
    }
    return last_err orelse error.ConnectionRefused;
}

fn writeAll(fd: compat.socket_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        sent += try compat.write(fd, bytes[sent..]);
    }
}

fn parseContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len < 15) continue;
        if (!std.ascii.startsWithIgnoreCase(line, "content-length:")) continue;
        const raw = std.mem.trim(u8, line["content-length:".len..], " \t");
        return std.fmt.parseInt(usize, raw, 10) catch null;
    }
    return null;
}

fn readOne(fd: compat.socket_t, buf: []u8) ![]u8 {
    var n: usize = 0;
    var header_end: ?usize = null;
    var body_len: usize = 0;
    while (n < buf.len) {
        const got = try compat.read(fd, buf[n..]);
        if (got == 0) return error.Closed;
        n += got;
        if (header_end == null) {
            if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n")) |idx| {
                header_end = idx + 4;
                body_len = parseContentLength(buf[0..idx]) orelse 0;
            }
        }
        if (header_end) |he| {
            if (n >= he + body_len) return buf[0 .. he + body_len];
        }
    }
    return error.ResponseTooLarge;
}

fn expectOk(bytes: []const u8) !void {
    if (bytes.len < 12 or !std.mem.startsWith(u8, bytes, "HTTP/")) return error.InvalidResponse;
    const line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return error.InvalidResponse;
    if (std.mem.indexOf(u8, bytes[0..line_end], " 200 ") == null) return error.BadStatus;
}

const Result = struct {
    ok: usize = 0,
    stalls: usize = 0,
    err: usize = 0,
    reconnects: usize = 0,
};

fn keepAliveWorker(result: *Result, port: u16, request: []const u8, deadline_ns: i96) void {
    var buf: [2048]u8 = undefined;
    var fd = connectPort(port) catch {
        result.err += 1;
        return;
    };
    defer compat.close(fd);

    while (nowNs() < deadline_ns) {
        var replace = false;

        if (writeAll(fd, request)) {
            if (readOne(fd, &buf)) |resp| {
                if (expectOk(resp)) {
                    result.ok += 1;
                } else |_| {
                    result.err += 1;
                }
            } else |err| switch (err) {
                error.WouldBlock, error.ConnectionTimedOut => {
                    result.stalls += 1;
                    replace = true;
                },
                error.Closed, error.ConnectionResetByPeer, error.BrokenPipe => replace = true,
                else => {
                    result.err += 1;
                    replace = true;
                },
            }
        } else |_| {
            replace = true;
        }

        if (!replace) continue;
        if (nowNs() >= deadline_ns) return;
        compat.close(fd);
        fd = connectPort(port) catch {
            result.err += 1;
            return;
        };
        result.reconnects += 1;
    }
}

fn runEngine(engine: *zinc.Engine) void {
    engine.run() catch {};
}

fn startEngine(engine: *zinc.Engine) !std.Thread {
    const thread = try std.Thread.spawn(.{}, runEngine, .{engine});
    sleepMs(10);
    return thread;
}

fn stopEngine(engine: *zinc.Engine, thread: std.Thread) void {
    engine.shutdown(0);
    thread.join();
}

const Measurement = struct {
    clients: usize = 0,
    ok: usize = 0,
    stalls: usize = 0,
    err: usize = 0,
    reconnects: usize = 0,
    elapsed_ns: i96 = 0,

    fn perSecond(self: Measurement) f64 {
        return rps(self.ok, self.elapsed_ns);
    }

    fn lossRate(self: Measurement) f64 {
        const total = self.ok + self.stalls + self.err;
        if (total == 0) return 1;
        return @as(f64, @floatFromInt(self.stalls + self.err)) / @as(f64, @floatFromInt(total));
    }
};

fn measure(port: u16, request: []const u8, clients: usize, window_ms: i64) !Measurement {
    const allocator = std.testing.allocator;
    const results = try allocator.alloc(Result, clients);
    defer allocator.free(results);
    for (results) |*r| r.* = .{};
    const threads = try allocator.alloc(std.Thread, clients);
    defer allocator.free(threads);

    {
        var warm: Result = .{};
        keepAliveWorker(&warm, port, request, nowNs() + 20 * std.time.ns_per_ms);
    }

    const t0 = nowNs();
    const deadline = t0 + @as(i96, window_ms) * std.time.ns_per_ms;
    for (0..clients) |i| {
        threads[i] = try std.Thread.spawn(.{}, keepAliveWorker, .{
            &results[i],
            port,
            request,
            deadline,
        });
    }
    for (threads) |t| t.join();
    const elapsed = nowNs() - t0;

    var m = Measurement{ .clients = clients, .elapsed_ns = elapsed };
    for (results) |r| {
        m.ok += r.ok;
        m.stalls += r.stalls;
        m.err += r.err;
        m.reconnects += r.reconnects;
    }
    return m;
}

fn printMeasurement(name: []const u8, m: Measurement) void {
    std.debug.print(
        "  {s}: {d} clients, {d} ok, {d} stalled, {d} err, {d} reconnects in {d:.0}ms — {d:.0} req/s\n",
        .{
            name,
            m.clients,
            m.ok,
            m.stalls,
            m.err,
            m.reconnects,
            @as(f64, @floatFromInt(@max(m.elapsed_ns, 1))) / 1e6,
            m.perSecond(),
        },
    );
}

fn report(name: []const u8, m: Measurement, min_rps: f64) !void {
    printMeasurement(name, m);
    try testing.expect(m.ok > 0);
    if (m.lossRate() > 0.05) {
        std.debug.print(
            "  FAIL: {s} lost {d:.1}% of exchanges (limit 5%)\n",
            .{ name, m.lossRate() * 100 },
        );
        return error.TooManyLostExchanges;
    }
    if (m.perSecond() < min_rps) {
        std.debug.print(
            "  FAIL: {s} at {d:.0} req/s, below floor {d:.0} [{s}]\n",
            .{ name, m.perSecond(), min_rps, @tagName(builtin.mode) },
        );
        return error.PerformanceRegression;
    }
}

fn newEngine(threads: u8) !*zinc.Engine {
    return zinc.Engine.init(.{
        .addr = "127.0.0.1",
        .port = 0,
        .num_threads = threads,
        .read_buffer_len = 8192,
        .header_buffer_len = 1024,
        .body_buffer_len = 4096,
        .stack_size = 1024 * 1024,
        .max_conn = 10_000,
    });
}

const plaintext_request = "GET /plaintext HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n";
const json_request = "GET /json HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n";

fn jsonHandler(ctx: *zinc.Context) anyerror!void {
    try ctx.json(.{ .message = "Hello, World!" }, .{});
}

fn measureFresh(
    engine_threads: u8,
    path: []const u8,
    handler: zinc.HandlerFn,
    request: []const u8,
    clients: usize,
    window_ms: i64,
) !Measurement {
    var engine = try newEngine(engine_threads);
    defer engine.deinit();
    try engine.getRouter().get(path, handler);

    const thread = try startEngine(engine);
    defer stopEngine(engine, thread);

    return measure(engine.getPort(), request, clients, window_ms);
}

test "perf: keep-alive plaintext throughput" {
    const m = try measureFresh(
        4,
        "/plaintext",
        harness.text("Hello, World!"),
        plaintext_request,
        1,
        windowMs(),
    );
    try report("keep-alive plaintext", m, floor(1_500, 8_000));
}

test "perf: keep-alive json throughput" {
    const m = try measureFresh(4, "/json", jsonHandler, json_request, 1, windowMs());
    try report("keep-alive json", m, floor(1_200, 6_000));
}

test "perf: keep-alive concurrent plaintext" {
    const m = try measureFresh(
        4,
        "/plaintext",
        harness.text("Hello, World!"),
        plaintext_request,
        8,
        windowMs(),
    );
    try report("keep-alive concurrent plaintext", m, floor(3_000, min_rps_release));
}

test "perf: keep-alive throughput vs baseline" {
    const client_counts: []const usize = if (is_debug)
        &.{ 1, 4, 8 }
    else
        &.{ 1, 2, 4, 8, 16, 32 };
    const window = windowMs();

    std.debug.print(
        "\n  concurrency sweep, {d}ms window each, fresh engine per point [{s}]\n",
        .{ window, @tagName(builtin.mode) },
    );

    var best: f64 = 0;
    var best_clients: usize = 0;
    var total_stalls: usize = 0;
    for (client_counts) |clients| {
        const m = try measureFresh(
            4,
            "/plaintext",
            harness.text("Hello, World!"),
            plaintext_request,
            clients,
            window,
        );
        const got = m.perSecond();
        if (got > best) {
            best = got;
            best_clients = clients;
        }
        total_stalls += m.stalls;
        std.debug.print(
            "  {d: >3} conn: {d: >7.0} req/s  ({d} ok, {d} stalled, {d} err, loss {d:.1}%)\n",
            .{ clients, got, m.ok, m.stalls, m.err, m.lossRate() * 100 },
        );
        try testing.expect(m.ok > 0);
        if (m.lossRate() > 0.05) {
            std.debug.print(
                "  FAIL: {d} conn lost {d:.1}% of exchanges (limit 5%)\n",
                .{ clients, m.lossRate() * 100 },
            );
            return error.TooManyLostExchanges;
        }
    }

    printSummary(best);
    std.debug.print(
        "  best {d:.0} req/s at {d} connection(s); {d} stalled response(s) across the sweep\n",
        .{ best, best_clients, total_stalls },
    );

    const min_best = floor(3_000, min_rps_release);
    if (best < min_best) {
        std.debug.print(
            "  FAIL: best {d:.0} req/s below floor {d:.0} [{s}]\n",
            .{ best, min_best, @tagName(builtin.mode) },
        );
        return error.PerformanceRegression;
    }
}
