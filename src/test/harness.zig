//! Shared test harness for the Zinc test suite.
//!
//! Goals:
//!   * One well-defined way to build a `Context` so no test reads `undefined`
//!     memory (`Request.head`, `Request.method` and `Context.recv_buf` all
//!     default to `undefined` in the framework and are read by production code).
//!   * Ownership is explicit: every builder returns a value with a `deinit()`
//!     that releases exactly what it allocated, so `std.testing.allocator`
//!     leak detection is meaningful.
//!   * Assertion helpers that produce useful failures instead of bare
//!     `expect(false)`.

const std = @import("std");

const zinc = @import("../zinc.zig");

pub const Context = zinc.Context;
pub const Request = zinc.Request;
pub const Response = zinc.Response;
pub const Route = zinc.Route;
pub const Router = zinc.Router;
pub const HandlerFn = zinc.HandlerFn;

const Head = std.http.Server.Request.Head;

/// A fully-initialized `Head`. The framework declares `Request.head` as
/// `undefined`, but `Context.getPostFormMap` reads `content_type` and
/// `content_length`, and `Context.doRequest` reads `keep_alive`. Tests must
/// therefore always supply a real value.
pub fn head(options: struct {
    method: std.http.Method = .GET,
    target: []const u8 = "/",
    version: std.http.Version = .@"HTTP/1.1",
    expect: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    content_length: ?u64 = null,
    transfer_encoding: std.http.TransferEncoding = .none,
    transfer_compression: std.http.ContentEncoding = .identity,
    keep_alive: bool = false,
}) Head {
    return .{
        .method = options.method,
        .target = options.target,
        .version = options.version,
        .expect = options.expect,
        .content_type = options.content_type,
        .content_length = options.content_length,
        .transfer_encoding = options.transfer_encoding,
        .transfer_compression = options.transfer_compression,
        .keep_alive = options.keep_alive,
    };
}

/// Options for `newContext`.
pub const ContextOptions = struct {
    method: std.http.Method = .GET,
    target: []const u8 = "/",
    /// Bytes that would have been read off the socket. `getPostFormMap` reads
    /// the request body from here.
    recv_buf: []u8 = &.{},
    /// Content-Type reported by the request head.
    content_type: ?[]const u8 = null,
    /// Content-Length reported by the request head. When null and a body is
    /// supplied via `recv_buf`, it defaults to `recv_buf.len`.
    content_length: ?u64 = null,
    keep_alive: bool = false,
};

/// A `Context` plus the ownership bookkeeping needed to tear it down.
///
/// `Context.destroy` already frees the request and response, so `deinit` only
/// has to call it. Kept as a distinct type so tests never have to remember
/// which of `destroy` / `destroyWithoutRequestResponse` applies.
pub const TestContext = struct {
    ctx: *Context,

    pub fn deinit(self: TestContext) void {
        self.ctx.destroy();
    }
};

/// Build a `Context` with every field the framework reads initialized.
pub fn newContext(allocator: std.mem.Allocator, options: ContextOptions) !TestContext {
    const req = try Request.init(.{
        .allocator = allocator,
        .target = options.target,
        .method = options.method,
        .head = head(.{
            .method = options.method,
            .target = options.target,
            .content_type = options.content_type,
            .content_length = options.content_length orelse
                if (options.recv_buf.len > 0) options.recv_buf.len else null,
            .keep_alive = options.keep_alive,
        }),
    });
    errdefer req.deinit();

    const res = try Response.init(.{
        .allocator = allocator,
        .req_method = options.method,
    });
    errdefer res.deinit();

    const ctx = try Context.init(.{
        .allocator = allocator,
        .request = req,
        .response = res,
        .recv_buf = options.recv_buf,
    });
    return .{ .ctx = ctx };
}

/// Build a context carrying a `application/x-www-form-urlencoded` body.
/// `body` must outlive the returned context (string literals are ideal).
pub fn newFormContext(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    target: []const u8,
    body: []u8,
) !TestContext {
    return newContext(allocator, .{
        .method = method,
        .target = target,
        .recv_buf = body,
        .content_type = "application/x-www-form-urlencoded",
    });
}

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

pub fn expectStatus(ctx: *Context, expected: std.http.Status) !void {
    try std.testing.expectEqual(expected, ctx.response.status);
}

/// Assert the response body matches exactly. Fails with a clear message when
/// no body was ever set, instead of panicking on `.?`.
pub fn expectBody(ctx: *Context, expected: []const u8) !void {
    const body = ctx.response.body orelse {
        std.debug.print("expected body \"{s}\", but response body was null\n", .{expected});
        return error.TestExpectedBody;
    };
    try std.testing.expectEqualStrings(expected, body);
}

pub fn expectNoBody(ctx: *Context) !void {
    if (ctx.response.body) |body| {
        std.debug.print("expected no body, found \"{s}\"\n", .{body});
        return error.TestUnexpectedBody;
    }
}

/// Assert the body contains `needle`. Useful for JSON, where field order is
/// an implementation detail.
pub fn expectBodyContains(ctx: *Context, needle: []const u8) !void {
    const body = ctx.response.body orelse {
        std.debug.print("expected body containing \"{s}\", but body was null\n", .{needle});
        return error.TestExpectedBody;
    };
    if (std.mem.indexOf(u8, body, needle) == null) {
        std.debug.print("expected body to contain \"{s}\", got \"{s}\"\n", .{ needle, body });
        return error.TestExpectedBodySubstring;
    }
}

/// Find a response header by name (case-insensitive), returning the first match.
/// `Response.setHeader` appends rather than replacing, so callers that care
/// about duplicates should use `headerValues`.
pub fn findHeader(ctx: *Context, name: []const u8) ?std.http.Header {
    for (ctx.response.getHeaders()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h;
    }
    return null;
}

pub fn expectHeader(ctx: *Context, name: []const u8, expected: []const u8) !void {
    const h = findHeader(ctx, name) orelse {
        std.debug.print("expected header \"{s}\" to be present\n", .{name});
        return error.TestExpectedHeader;
    };
    try std.testing.expectEqualStrings(expected, h.value);
}

pub fn expectNoHeader(ctx: *Context, name: []const u8) !void {
    if (findHeader(ctx, name)) |h| {
        std.debug.print("expected no \"{s}\" header, found value \"{s}\"\n", .{ name, h.value });
        return error.TestUnexpectedHeader;
    }
}

/// Count how many times a header name appears.
pub fn countHeader(ctx: *Context, name: []const u8) usize {
    var count: usize = 0;
    for (ctx.response.getHeaders()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Handler execution tracing
// ---------------------------------------------------------------------------

/// `HandlerFn` is a bare function pointer, so a handler cannot capture state.
/// `Trace` is process-global scratch space that named handlers append to,
/// letting a test assert the exact order in which a middleware chain ran.
///
/// Tests using it must call `Trace.reset()` first and must not run in
/// parallel with each other. Zig runs the tests in a single test binary
/// sequentially, so that holds by default.
pub const Trace = struct {
    var entries: [64][]const u8 = undefined;
    var count: usize = 0;
    var overflowed: bool = false;

    pub fn reset() void {
        count = 0;
        overflowed = false;
    }

    /// Record that `label` executed. Safe to call from a handler.
    pub fn record(label: []const u8) void {
        if (count >= entries.len) {
            overflowed = true;
            return;
        }
        entries[count] = label;
        count += 1;
    }

    pub fn items() []const []const u8 {
        return entries[0..count];
    }

    fn dump(what: []const u8, labels: []const []const u8) void {
        std.debug.print("  {s}: [", .{what});
        for (labels, 0..) |label, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{label});
        }
        std.debug.print("]\n", .{});
    }

    /// Assert the recorded labels match `expected` exactly, in order.
    pub fn expectOrder(expected: []const []const u8) !void {
        if (overflowed) return error.TestTraceOverflow;
        const actual = items();
        if (actual.len != expected.len) {
            std.debug.print("trace length mismatch: expected {d} entries, got {d}\n", .{
                expected.len, actual.len,
            });
            dump("expected", expected);
            dump("actual", actual);
            return error.TestTraceLengthMismatch;
        }
        for (expected, actual, 0..) |want, got, i| {
            if (!std.mem.eql(u8, want, got)) {
                std.debug.print("trace[{d}]: expected \"{s}\", got \"{s}\"\n", .{ i, want, got });
                return error.TestTraceMismatch;
            }
        }
    }
};

/// Build a handler that records `label` and then continues the chain.
/// Because the label must be comptime-known, this is a generic factory.
pub fn tracingMiddleware(comptime label: []const u8) HandlerFn {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            Trace.record(label ++ ":before");
            try ctx.next();
            Trace.record(label ++ ":after");
        }
    }.handle;
}

/// Build a terminal handler that records `label` and writes `body`.
pub fn tracingHandler(comptime label: []const u8, comptime body: []const u8) HandlerFn {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            Trace.record(label);
            try ctx.text(body, .{});
        }
    }.handle;
}

/// A handler that writes a fixed plain-text body. The most common stub.
pub fn textHandler(comptime body: []const u8) HandlerFn {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.text(body, .{});
        }
    }.handle;
}

/// A handler that always fails, to exercise error propagation.
pub fn failingHandler(comptime err: anyerror) HandlerFn {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            _ = ctx;
            return err;
        }
    }.handle;
}

/// A handler that does nothing at all.
pub fn noopHandler(ctx: *Context) anyerror!void {
    _ = ctx;
}

/// Run a route's handler chain against `ctx` the way the server would,
/// without touching a socket. `Route.handle` calls `ctx.handle`, which also
/// tries to write the response, so tests drive the chain directly instead.
pub fn runChain(ctx: *Context, route: *Route) !void {
    ctx.handlers = route.handlers;
    try ctx.handlersProcess();
}
