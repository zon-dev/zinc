const std = @import("std");
const Method = std.http.Method;
const URL = @import("url");

const zinc = @import("../zinc.zig");

const Context = zinc.Context;
const Request = zinc.Request;
const Response = zinc.Response;
const HandlerFn = zinc.HandlerFn;

pub const Route = @This();
const Self = @This();

allocator: std.mem.Allocator,

method: Method,

path: []const u8,

handlers: std.ArrayList(HandlerFn),

pub fn init(self: Self) anyerror!*Route {
    const route = try self.allocator.create(Route);
    errdefer self.allocator.destroy(route);

    route.* = .{
        .allocator = self.allocator,
        .method = self.method,
        .path = self.path,
        .handlers = std.ArrayList(HandlerFn).init(self.allocator),
    };

    return route;
}

pub fn create(allocator: std.mem.Allocator, path: []const u8, http_method: Method, handlers: []const HandlerFn) anyerror!*Route {
    var r = try Route.init(.{
        .method = http_method,
        .path = path,
        .allocator = allocator,
        .handlers = std.ArrayList(HandlerFn).init(allocator),
    });
    try r.handlers.appendSlice(handlers);
    return r;
}

pub fn deinit(self: *Self) void {
    if (self.handlers.items.len > 0) {
        self.handlers.deinit();
    }
    // self.allocator.free(self.path);

    const allocator = self.allocator;
    allocator.destroy(self);
}

pub const RouteError = error{
    None,

    // 404 Not Found
    NotFound,
    // 405 Method Not Allowed
    MethodNotAllowed,

    // Handlers is empty
    HandlersEmpty,
};

pub fn any(path: []const u8, handler: anytype) Route {
    const ms = [_]Method{ .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS, .HEAD, .CONNECT, .TRACE };
    for (ms) |m| {
        try create(path, m, handler);
    }
}

pub fn isHandlerExists(self: *Route, handler: HandlerFn) bool {
    for (self.handlers.items) |h| {
        if (h == handler) {
            return true;
        }
    }
    return false;
}

pub fn get(path: []const u8, handler: anytype) Route {
    return create(path, .GET, handler);
}

pub fn post(path: []const u8, handler: anytype) Route {
    return create(path, .POST, handler);
}
pub fn put(path: []const u8, handler: anytype) Route {
    return create(path, .PUT, handler);
}
pub fn delete(path: []const u8, handler: anytype) Route {
    return create(path, .DELETE, handler);
}
pub fn patch(path: []const u8, handler: anytype) Route {
    return create(path, .PATCH, handler);
}
pub fn options(path: []const u8, handler: anytype) Route {
    return create(path, .OPTIONS, handler);
}
pub fn head(path: []const u8, handler: anytype) Route {
    return create(path, .HEAD, handler);
}
pub fn connect(path: []const u8, handler: anytype) Route {
    return create(path, .CONNECT, handler);
}
pub fn trace(path: []const u8, handler: anytype) Route {
    return create(path, .TRACE, handler);
}

pub fn getPath(self: *Route) []const u8 {
    return self.path;
}

pub fn getHandler(self: *Route) HandlerFn {
    return &self.handler;
}

pub fn handle(self: *Route, ctx: *Context) anyerror!void {
    ctx.handlers = self.handlers;
    try ctx.handle();
}

pub fn isMethodAllowed(self: *Route, method: Method) bool {
    if (self.method == method) {
        return true;
    }

    return false;
}

pub fn isPathMatch(self: *Route, path: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(self.path, "*")) {
        return true;
    }
    return std.ascii.eqlIgnoreCase(self.path, path);
}

pub fn isStaticRoute(self: *Route, target: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(self.path, "*")) {
        return true;
    }

    // not server root
    if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, self.path, "") or std.mem.eql(u8, self.path, "/")) {
        return false;
    }

    var targets = std.mem.splitSequence(u8, target, "/");
    var ps = std.mem.splitSequence(u8, self.path, "/");

    _ = targets.first();
    _ = ps.first();

    while (true) {
        const t = targets.next().?;
        const pp = ps.next().?;
        if (std.ascii.eqlIgnoreCase(t, "") or std.ascii.eqlIgnoreCase(pp, "")) {
            break;
        }

        if (std.ascii.eqlIgnoreCase(t, pp)) {
            return true;
        }
        return false;
    }

    return std.ascii.eqlIgnoreCase(self.path, target);
}

pub fn isMatch(self: *Route, method: Method, path: []const u8) bool {
    if (self.isPathMatch(path) and self.isMethodAllowed(method)) {
        return true;
    }

    return false;
}

pub fn use(self: *Route, handlers: []const HandlerFn) anyerror!void {
    if (self.handlers.items.len == 0) return try self.handlers.appendSlice(handlers);

    // const old_chain = try self.handlers.toOwnedSlice();
    // const old_chain = try self.handlers.toOwnedSlice();
    // self.allocator.free(old_chain);

    // const capacity = old_chain.len + handlers.len;
    // try self.handlers.ensureTotalCapacity(capacity);

    try self.handlers.appendSlice(handlers);
    // try self.handlers.appendSlice(old_chain);
}
