//! Shared test kit for Zinc.
//!
//! Layout:
//!   * **fixtures** — fully-initialized Request / Response / Context / Router /
//!     RouteTree, so tests never read `undefined` (`Request.head`, `Request.method`,
//!     `Context.recv_buf` default to `undefined` in production).
//!   * **App** — in-process client: register routes, `dispatch` a request, assert
//!     the exchange. No sockets. Same ownership story as production (`testing.allocator`
//!     leak detection is meaningful).
//!   * **stubs** — `text` / tracing / failing handlers. `HandlerFn` cannot capture
//!     state, so `Trace` is process-global scratch space for chain-order tests.

const std = @import("std");

const zinc = @import("../zinc.zig");

pub const Context = zinc.Context;
pub const Request = zinc.Request;
pub const Response = zinc.Response;
pub const Route = zinc.Route;
pub const Router = zinc.Router;
pub const RouteTree = zinc.RouteTree;
pub const HandlerFn = zinc.HandlerFn;
pub const RouteError = Route.RouteError;

const Head = std.http.Server.Request.Head;

/// Every HTTP method the framework registers via `any()`.
pub const methods = [_]std.http.Method{
    .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS, .HEAD, .CONNECT, .TRACE,
};

pub const assets = struct {
    pub const dir = "src/test/assets";
    pub const style_css = dir ++ "/style.css";
    pub const style_css_body = "/* style.css */";
    pub const script_js = dir ++ "/js/script.js";
    pub const script_js_body = "// script.js";
};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

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

pub const ContextOptions = struct {
    method: std.http.Method = .GET,
    target: []const u8 = "/",
    recv_buf: []u8 = &.{},
    content_type: ?[]const u8 = null,
    content_length: ?u64 = null,
    keep_alive: bool = false,
};

pub const TestContext = struct {
    ctx: *Context,

    pub fn deinit(self: TestContext) void {
        self.ctx.destroy();
    }
};

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

pub fn newRequest(allocator: std.mem.Allocator, method: std.http.Method, target: []const u8) !*Request {
    return Request.init(.{
        .allocator = allocator,
        .method = method,
        .target = target,
        .head = head(.{ .method = method, .target = target }),
    });
}

pub fn newResponse(allocator: std.mem.Allocator) !*Response {
    return Response.init(.{ .allocator = allocator });
}

pub fn newRouter(allocator: std.mem.Allocator) !*Router {
    return Router.init(.{ .allocator = allocator });
}

pub fn newTree(allocator: std.mem.Allocator) !*RouteTree {
    return RouteTree.init(.{
        .value = "/",
        .full_path = "/",
        .allocator = allocator,
        .children = std.StringHashMap(*RouteTree).init(allocator),
        .routes = std.array_list.Managed(*Route).init(allocator),
    });
}

pub fn borrowedRoute(allocator: std.mem.Allocator, method: std.http.Method, path: []const u8) !*Route {
    return Route.init(.{
        .method = method,
        .path = path,
        .allocator = allocator,
        .handlers = std.array_list.Managed(HandlerFn).init(allocator),
    });
}

pub fn routeCount(router: *Router) usize {
    const routes = router.getRoutes();
    defer routes.deinit();
    return routes.items.len;
}

/// Run a route's handler chain without writing to a socket.
/// `Route.handle` also calls `ctx.doRequest`, which needs a live connection.
pub fn runChain(ctx: *Context, route: *Route) !void {
    ctx.handlers = route.handlers;
    try ctx.handlersProcess();
}

// ---------------------------------------------------------------------------
// App — in-process request/response
// ---------------------------------------------------------------------------

pub const RequestSpec = struct {
    method: std.http.Method = .GET,
    target: []const u8 = "/",
    recv_buf: []u8 = &.{},
    content_type: ?[]const u8 = null,
    content_length: ?u64 = null,
    keep_alive: bool = false,
    /// Request headers applied after the context is built (`Request.setHeader`).
    req_headers: []const std.http.Header = &.{},
};

/// One in-process request/response. Owns the `Context` (and therefore the
/// request and response). Assertions live here so tests read as
/// `try res.expectBody("ok")` rather than reaching into internals.
pub const Exchange = struct {
    ctx: *Context,

    pub fn deinit(self: Exchange) void {
        self.ctx.destroy();
    }

    pub fn expectStatus(self: Exchange, expected: std.http.Status) !void {
        try std.testing.expectEqual(expected, self.ctx.response.status);
    }

    pub fn expectBody(self: Exchange, expected: []const u8) !void {
        const body = self.ctx.response.body orelse {
            std.debug.print("expected body \"{s}\", but response body was null\n", .{expected});
            return error.TestExpectedBody;
        };
        try std.testing.expectEqualStrings(expected, body);
    }

    pub fn expectNoBody(self: Exchange) !void {
        if (self.ctx.response.body) |body| {
            std.debug.print("expected no body, found \"{s}\"\n", .{body});
            return error.TestUnexpectedBody;
        }
    }

    pub fn expectBodyContains(self: Exchange, needle: []const u8) !void {
        const body = self.ctx.response.body orelse {
            std.debug.print("expected body containing \"{s}\", but body was null\n", .{needle});
            return error.TestExpectedBody;
        };
        if (std.mem.indexOf(u8, body, needle) == null) {
            std.debug.print("expected body to contain \"{s}\", got \"{s}\"\n", .{ needle, body });
            return error.TestExpectedBodySubstring;
        }
    }

    pub fn expectBodyNotContains(self: Exchange, needle: []const u8) !void {
        const body = self.ctx.response.body orelse return;
        if (std.mem.indexOf(u8, body, needle) != null) {
            std.debug.print("expected body not to contain \"{s}\", got \"{s}\"\n", .{ needle, body });
            return error.TestUnexpectedBodySubstring;
        }
    }

    pub fn findHeader(self: Exchange, name: []const u8) ?std.http.Header {
        for (self.ctx.response.getHeaders()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h;
        }
        return null;
    }

    pub fn expectHeader(self: Exchange, name: []const u8, expected: []const u8) !void {
        const h = self.findHeader(name) orelse {
            std.debug.print("expected header \"{s}\" to be present\n", .{name});
            return error.TestExpectedHeader;
        };
        try std.testing.expectEqualStrings(expected, h.value);
    }

    pub fn expectNoHeader(self: Exchange, name: []const u8) !void {
        if (self.findHeader(name)) |h| {
            std.debug.print("expected no \"{s}\" header, found value \"{s}\"\n", .{ name, h.value });
            return error.TestUnexpectedHeader;
        }
    }

    pub fn headerCount(self: Exchange, name: []const u8) usize {
        var count: usize = 0;
        for (self.ctx.response.getHeaders()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) count += 1;
        }
        return count;
    }
};

/// In-process application: a router plus a dispatcher that never opens a socket.
pub const App = struct {
    allocator: std.mem.Allocator,
    router: *Router,

    pub fn init(allocator: std.mem.Allocator) !App {
        return .{
            .allocator = allocator,
            .router = try Router.init(.{ .allocator = allocator }),
        };
    }

    pub fn deinit(self: *App) void {
        self.router.deinit();
    }

    /// Look up the route and run its chain. Lookup errors (`NotFound`,
    /// `MethodNotAllowed`) propagate so tests can `expectError` them.
    pub fn dispatch(self: *App, spec: RequestSpec) !Exchange {
        const tc = try newContext(self.allocator, .{
            .method = spec.method,
            .target = spec.target,
            .recv_buf = spec.recv_buf,
            .content_type = spec.content_type,
            .content_length = spec.content_length,
            .keep_alive = spec.keep_alive,
        });
        errdefer tc.deinit();

        for (spec.req_headers) |h| {
            try tc.ctx.request.setHeader(h.name, h.value);
        }

        const route = try self.router.getRoute(spec.method, spec.target);
        try runChain(tc.ctx, route);
        return .{ .ctx = tc.ctx };
    }

    pub fn get(self: *App, target: []const u8) !Exchange {
        return self.dispatch(.{ .method = .GET, .target = target });
    }

    pub fn post(self: *App, target: []const u8, body: []u8) !Exchange {
        return self.dispatch(.{
            .method = .POST,
            .target = target,
            .recv_buf = body,
        });
    }
};

// ---------------------------------------------------------------------------
// Assertions on a raw Context (unit tests that never go through a router)
// ---------------------------------------------------------------------------

pub fn expectStatus(ctx: *Context, expected: std.http.Status) !void {
    try Exchange.expectStatus(.{ .ctx = ctx }, expected);
}

pub fn expectBody(ctx: *Context, expected: []const u8) !void {
    try Exchange.expectBody(.{ .ctx = ctx }, expected);
}

pub fn expectNoBody(ctx: *Context) !void {
    try Exchange.expectNoBody(.{ .ctx = ctx });
}

pub fn expectBodyContains(ctx: *Context, needle: []const u8) !void {
    try Exchange.expectBodyContains(.{ .ctx = ctx }, needle);
}

pub fn expectHeader(ctx: *Context, name: []const u8, expected: []const u8) !void {
    try Exchange.expectHeader(.{ .ctx = ctx }, name, expected);
}

pub fn expectNoHeader(ctx: *Context, name: []const u8) !void {
    try Exchange.expectNoHeader(.{ .ctx = ctx }, name);
}

pub fn findHeader(ctx: *Context, name: []const u8) ?std.http.Header {
    return Exchange.findHeader(.{ .ctx = ctx }, name);
}

pub fn countHeader(ctx: *Context, name: []const u8) usize {
    return Exchange.headerCount(.{ .ctx = ctx }, name);
}

// ---------------------------------------------------------------------------
// Handler stubs
// ---------------------------------------------------------------------------

pub const Trace = struct {
    var entries: [64][]const u8 = undefined;
    var count: usize = 0;
    var overflowed: bool = false;

    pub fn reset() void {
        count = 0;
        overflowed = false;
    }

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

pub fn tracingMiddleware(comptime label: []const u8) HandlerFn {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            Trace.record(label ++ ":before");
            try ctx.next();
            Trace.record(label ++ ":after");
        }
    }.handle;
}

pub fn tracingHandler(comptime label: []const u8, comptime body: []const u8) HandlerFn {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            Trace.record(label);
            try ctx.text(body, .{});
        }
    }.handle;
}

pub fn text(comptime body: []const u8) HandlerFn {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.text(body, .{});
        }
    }.handle;
}

/// Alias kept so existing test files that still say `textHandler` compile
/// during the migration. Prefer `text`.
pub const textHandler = text;

pub fn failingHandler(comptime err: anyerror) HandlerFn {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            _ = ctx;
            return err;
        }
    }.handle;
}

pub fn noopHandler(_: *Context) anyerror!void {}

/// Parse `buf` as a request line. `buf` must outlive the returned parser
/// (`target` is a slice into it).
pub fn parseInto(buf: []u8) !Router.Parser {
    var parser = Router.Parser.init(buf);
    _ = try parser.parse();
    return parser;
}
