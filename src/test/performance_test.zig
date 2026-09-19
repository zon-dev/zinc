//! Performance regression tests.
//!
//! These are *floors*, not microbenchmarks for the leaderboard. Debug builds
//! (and `testing.allocator`) are much slower than ReleaseFast; floors scale
//! with `builtin.mode` so `zig build test` stays meaningful and
//! `zig build perf` (ReleaseFast) catches real throughput regressions.
//!
//! Layout:
//!   * CPU/in-process — parser, router lookup, handler, App.dispatch
//!   * HTTP e2e — blocking sockets through `posix_compat`, Content-Length reads
//!     (the server currently keeps the connection open after `connection: close`,
//!     so waiting for EOF hangs)
//!
//! Names are prefixed `perf:` so `zig build perf` can filter them.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const compat = @import("../zinc/posix_compat.zig");
const harness = @import("harness.zig");

const Parser = zinc.Router.Parser;
const Context = zinc.Context;

const is_debug = builtin.mode == .debug;

fn stdIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs() i96 {
    return std.Io.Clock.now(.awake, stdIo()).nanoseconds;
}

fn sleepMs(ms: i64) void {
    stdIo().sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn iterations(debug_n: usize, release_n: usize) usize {
    return if (is_debug) debug_n else release_n;
}

fn floor(debug_min: f64, release_min: f64) f64 {
    return if (is_debug) debug_min else release_min;
}

fn reportAndCheck(name: []const u8, n: usize, elapsed_ns: i96, min_ops: f64) !void {
    const ns: f64 = @floatFromInt(@max(elapsed_ns, 1));
    const secs = ns / 1e9;
    const ops = @as(f64, @floatFromInt(n)) / secs;
    const ns_op = ns / @as(f64, @floatFromInt(n));
    std.debug.print(
        "  {s}: {d} in {d:.2}ms — {d:.0} ops/s ({d:.0} ns/op)  floor {d:.0} [{s}]\n",
        .{ name, n, secs * 1e3, ops, ns_op, min_ops, @tagName(builtin.mode) },
    );
    if (ops < min_ops) {
        std.debug.print("  FAIL: {s} below performance floor\n", .{name});
        return error.PerformanceRegression;
    }
}

fn bench(name: []const u8, n: usize, min_ops: f64, work: anytype) !void {
    const warmup = @min(n / 20 + 1, 200);
    var i: usize = 0;
    while (i < warmup) : (i += 1) try work.run();
    i = 0;
    const t0 = nowNs();
    while (i < n) : (i += 1) try work.run();
    try reportAndCheck(name, n, nowNs() - t0, min_ops);
}

fn resetResponse(res: *zinc.Response) void {
    if (res.body) |body| {
        res.allocator.free(body);
        res.body = null;
    }
    res.header.clearRetainingCapacity();
    res.status = .ok;
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
            const tv = std.posix.timeval{ .sec = 2, .usec = 0 };
            std.posix.setsockopt(
                fd,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVTIMEO,
                std.mem.asBytes(&tv),
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

/// Read one HTTP response by Content-Length. Do not wait for EOF: the engine
/// issues another read after writing `connection: close`.
fn readResponse(fd: compat.socket_t, buf: []u8) ![]u8 {
    var n: usize = 0;
    var header_end: ?usize = null;
    var body_len: usize = 0;
    while (n < buf.len) {
        const got = try compat.read(fd, buf[n..]);
        if (got == 0) break;
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
    if (n == 0) return error.NoResponse;
    return buf[0..n];
}

fn expectHttp200(bytes: []const u8) !void {
    if (bytes.len < 12 or !std.mem.startsWith(u8, bytes, "HTTP/")) return error.InvalidResponse;
    const line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return error.InvalidResponse;
    if (std.mem.indexOf(u8, bytes[0..line_end], " 200 ") == null) return error.BadStatus;
}

fn httpGet(port: u16, request: []const u8) !void {
    const fd = try connectPort(port);
    defer compat.close(fd);
    try writeAll(fd, request);
    var buf: [2048]u8 = undefined;
    const resp = try readResponse(fd, &buf);
    try expectHttp200(resp);
}

fn runEngine(engine: *zinc.Engine) void {
    engine.run() catch {};
}

fn startEngine(engine: *zinc.Engine) !std.Thread {
    const thread = try std.Thread.spawn(.{}, runEngine, .{engine});
    // Bind already happened in init; a short wait still avoids a refused burst.
    sleepMs(10);
    return thread;
}

fn stopEngine(engine: *zinc.Engine, thread: std.Thread) void {
    engine.shutdown(0);
    thread.join();
}

test "perf: parser request-line" {
    const n = iterations(40_000, 400_000);
    const line = "GET /plaintext HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    const Work = struct {
        buf: []u8,
        fn run(self: @This()) !void {
            var parser = Parser.init(self.buf);
            if (!try parser.parse()) return error.Incomplete;
            if (parser.method != .GET) return error.UnexpectedMethod;
        }
    };
    var buf: [line.len]u8 = line.*;
    try bench("parser request-line", n, floor(100_000, 1_000_000), Work{ .buf = &buf });
}

test "perf: router exact lookup" {
    const allocator = std.heap.page_allocator;
    var router = try zinc.Router.init(.{ .allocator = allocator });
    defer router.deinit();

    const handler = harness.text("ok");
    try router.get("/", handler);
    try router.get("/plaintext", handler);
    try router.get("/json", handler);
    try router.get("/healthz", handler);
    try router.get("/api/v1/users", handler);
    try router.get("/api/v1/users/profile", handler);
    try router.get("/api/v1/posts", handler);
    try router.get("/static/css/app.css", handler);
    try router.get("/static/js/app.js", handler);
    try router.get("/metrics", handler);

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/item/{d}", .{i});
        try router.get(path, handler);
    }

    const n = iterations(20_000, 200_000);
    const Work = struct {
        router: *zinc.Router,
        fn run(self: @This()) !void {
            _ = try self.router.getRoute(.GET, "/plaintext");
            _ = try self.router.getRoute(.GET, "/api/v1/users/profile");
            _ = try self.router.getRoute(.GET, "/item/42");
        }
    };
    // Three lookups per iteration.
    try bench("router exact lookup", n * 3, floor(50_000, 200_000), Work{ .router = router });
}

test "perf: router query-string lookup" {
    const allocator = std.heap.page_allocator;
    var router = try zinc.Router.init(.{ .allocator = allocator });
    defer router.deinit();
    try router.get("/search", harness.text("ok"));

    const n = iterations(4_000, 40_000);
    const Work = struct {
        router: *zinc.Router,
        fn run(self: @This()) !void {
            _ = try self.router.getRoute(.GET, "/search?q=zinc&page=2");
        }
    };
    // `getRoute` still parses a URL when `?` is present; this floor is lower
    // on purpose so the tax is visible next to the exact-path test.
    try bench("router query-string lookup", n, floor(10_000, 30_000), Work{ .router = router });
}

test "perf: handler text" {
    const allocator = std.heap.page_allocator;
    var tc = try harness.newContext(allocator, .{ .target = "/plaintext" });
    defer tc.deinit();
    const handler = harness.text("Hello, World!");

    const n = iterations(8_000, 80_000);
    const Work = struct {
        ctx: *Context,
        handler: zinc.HandlerFn,
        fn run(self: @This()) !void {
            resetResponse(self.ctx.response);
            try self.handler(self.ctx);
        }
    };
    try bench("handler text", n, floor(20_000, 80_000), Work{ .ctx = tc.ctx, .handler = handler });
}

test "perf: handler json" {
    const allocator = std.heap.page_allocator;
    var tc = try harness.newContext(allocator, .{ .target = "/json" });
    defer tc.deinit();
    const handler = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.json(.{ .message = "Hello, World!", .ok = true }, .{});
        }
    }.handle;

    const n = iterations(4_000, 40_000);
    const Work = struct {
        ctx: *Context,
        handler: zinc.HandlerFn,
        fn run(self: @This()) !void {
            resetResponse(self.ctx.response);
            try self.handler(self.ctx);
        }
    };
    try bench("handler json", n, floor(10_000, 40_000), Work{ .ctx = tc.ctx, .handler = handler });
}

test "perf: in-process dispatch" {
    const allocator = std.heap.page_allocator;
    var app = try harness.App.init(allocator);
    defer app.deinit();
    try app.router.get("/plaintext", harness.text("Hello, World!"));
    try app.router.get("/json", struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.json(.{ .message = "Hello, World!" }, .{});
        }
    }.handle);

    const n = iterations(3_000, 30_000);
    const Work = struct {
        app: *harness.App,
        fn run(self: @This()) !void {
            var text_res = try self.app.get("/plaintext");
            defer text_res.deinit();
            if (text_res.ctx.response.body) |body| {
                if (!std.mem.eql(u8, body, "Hello, World!")) return error.UnexpectedBody;
            } else return error.MissingBody;

            var json_res = try self.app.get("/json");
            defer json_res.deinit();
            const json_body = json_res.ctx.response.body orelse return error.MissingBody;
            if (std.mem.indexOf(u8, json_body, "Hello, World!") == null) return error.UnexpectedBody;
        }
    };
    try bench("in-process dispatch", n * 2, floor(5_000, 20_000), Work{ .app = &app });
}

test "perf: http plaintext sequential" {
    var engine = try zinc.Engine.init(.{
        .addr = "127.0.0.1",
        .port = 0,
        .num_threads = 2,
        .read_buffer_len = 8192,
        .header_buffer_len = 1024,
        .body_buffer_len = 4096,
        .stack_size = 1024 * 1024,
    });
    defer engine.deinit();
    try engine.getRouter().get("/plaintext", harness.text("Hello, World!"));

    const thread = try startEngine(engine);
    defer stopEngine(engine, thread);

    const port = engine.getPort();
    const request = "GET /plaintext HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    const n = iterations(80, 400);

    // Warm the accept path.
    try httpGet(port, request);

    const t0 = nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) try httpGet(port, request);
    // Sequential RPS is dominated by per-request latency (accept + handler hop +
    // event-loop wait). A 1ms loop timeout used to pin this near 800–1000 rps.
    try reportAndCheck("http plaintext sequential", n, nowNs() - t0, floor(1_500, 2_500));
}

test "perf: http json sequential" {
    var engine = try zinc.Engine.init(.{
        .addr = "127.0.0.1",
        .port = 0,
        .num_threads = 2,
        .read_buffer_len = 8192,
        .header_buffer_len = 1024,
        .body_buffer_len = 4096,
        .stack_size = 1024 * 1024,
    });
    defer engine.deinit();
    try engine.getRouter().get("/json", struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.json(.{ .message = "Hello, World!" }, .{});
        }
    }.handle);

    const thread = try startEngine(engine);
    defer stopEngine(engine, thread);

    const port = engine.getPort();
    const request = "GET /json HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    const n = iterations(60, 300);
    try httpGet(port, request);

    const t0 = nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) try httpGet(port, request);
    try reportAndCheck("http json sequential", n, nowNs() - t0, floor(1_500, 3_000));
}

const ClientResult = struct {
    ok: usize = 0,
    err: usize = 0,
};

fn concurrentWorker(result: *ClientResult, port: u16, request: []const u8, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        httpGet(port, request) catch {
            result.err += 1;
            continue;
        };
        result.ok += 1;
    }
}

test "perf: http concurrent clients" {
    var engine = try zinc.Engine.init(.{
        .addr = "127.0.0.1",
        .port = 0,
        .num_threads = 2,
        .read_buffer_len = 8192,
        .header_buffer_len = 1024,
        .body_buffer_len = 4096,
        .stack_size = 1024 * 1024,
    });
    defer engine.deinit();
    try engine.getRouter().get("/plaintext", harness.text("Hello, World!"));

    const thread = try startEngine(engine);
    defer stopEngine(engine, thread);

    const port = engine.getPort();
    const request: []const u8 = "GET /plaintext HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    try httpGet(port, request);

    const clients = 4;
    const per_client = iterations(20, 80);
    var results: [clients]ClientResult = undefined;
    for (&results) |*r| r.* = .{};
    var workers: [clients]std.Thread = undefined;

    const t0 = nowNs();
    for (0..clients) |i| {
        workers[i] = try std.Thread.spawn(.{}, concurrentWorker, .{
            &results[i],
            port,
            request,
            per_client,
        });
    }
    for (workers) |w| w.join();
    const elapsed = nowNs() - t0;

    var ok: usize = 0;
    var err_n: usize = 0;
    for (results) |r| {
        ok += r.ok;
        err_n += r.err;
    }
    std.debug.print("  http concurrent: {d} ok, {d} err\n", .{ ok, err_n });
    try testing.expect(err_n * 20 < ok + err_n); // < 5% errors
    try testing.expect(ok > 0);
    try reportAndCheck("http concurrent clients", ok, elapsed, floor(4_000, 8_000));
}
