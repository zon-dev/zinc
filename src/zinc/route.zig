const std = @import("std");

const logger = @import("logger.zig").init(.{});

const Context = @import("context.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");
const Handler = @import("handler.zig");
const Middleware = @import("middleware.zig");
const HandlerFn = Handler.HandlerFn;
const HandlerChain = Handler.Chain;

pub const Route = @This();
const Self = @This();

methods: []const std.http.Method = &.{
    .GET,
    .POST,
    .PUT,
    .DELETE,
    .PATCH,
    .OPTIONS,
    .HEAD,
    .CONNECT,
    .TRACE,
},

path: []const u8 = "*",

handler: Handler.HandlerFn = undefined,

pub fn init(self: Self) Route {
    return .{
        .methods = self.methods,
        .path = self.path,
        .handler = self.handler,
    };
}

pub const RouteError = error{
    // 404 Not Found
    NotFound,
    // 405 Method Not Allowed
    MethodNotAllowed,
};

pub fn match(self: *Route, method: std.http.Method, path: []const u8) anyerror!*Route {
    if (self.isPathMatch(path)) {
        if (self.isMethodAllowed(method)) {
            return self;
        }
        // found route but method not allowed
        return RouteError.MethodNotAllowed;
    }

    return RouteError.NotFound;
}

test "route matching error" {
    const TestCase = struct {
        route: Route,
        reqMethod: std.http.Method,
        reqPath: []const u8,
        expected: anyerror,
    };

    const foo_route = init(.{ .methods = &.{.GET}, .path = "/foo", .handler = undefined });
    const testCases = [_]TestCase{
        .{ .route = foo_route, .reqMethod = .POST, .reqPath = "/foo", .expected = RouteError.MethodNotAllowed },
        .{ .route = foo_route, .reqMethod = .POST, .reqPath = "foo", .expected = RouteError.NotFound },
        .{ .route = foo_route, .reqMethod = .GET, .reqPath = "/bar", .expected = RouteError.NotFound },
        .{ .route = foo_route, .reqMethod = .POST, .reqPath = "/bar", .expected = RouteError.NotFound },
    };

    for (testCases) |tc| {
        var route = tc.route;
        _ = route.match(tc.reqMethod, tc.reqPath) catch |err| {
            try std.testing.expect(err == tc.expected);
        };
    }
}

pub fn get(path: []const u8, handler: anytype) Route {
    return init(.{ .methods = &.{.GET}, .path = path, .handler = handler });
}

pub fn post(path: []const u8, handler: anytype) Route {
    return init(.{ .methods = &.{.POST}, .path = path, .handler = handler });
}
pub fn put(path: []const u8, handler: anytype) Route {
    return init(.{ .methods = &.{.PUT}, .path = path, .handler = handler });
}
pub fn delete(path: []const u8, handler: anytype) Route {
    return init(.{ .methods = &.{.DELETE}, .path = path, .handler = handler });
}
pub fn patch(path: []const u8, handler: anytype) Route {
    return init(.{ .methods = &.{.PATCH}, .path = path, .handler = handler });
}
pub fn options(path: []const u8, handler: anytype) Route {
    return init(.{ .methods = &.{.OPTIONS}, .path = path, .handler = handler });
}
pub fn head(path: []const u8, handler: anytype) Route {
    return init(.{ .methods = &.{.HEAD}, .path = path, .handler = handler });
}
pub fn connect(path: []const u8, handler: anytype) Route {
    return init(.{ .methods = &.{.CONNECT}, .path = path, .handler = handler });
}
pub fn trace(path: []const u8, handler: anytype) Route {
    return init(.{ .methods = &.{.TRACE}, .path = path, .handler = handler });
}

pub fn getPath(self: *Route) []const u8 {
    return self.path;
}

pub fn getHandler(self: *Route) Handler.HandlerFn {
    return &self.handler;
}

pub fn handle(self: *Route, ctx: *Context, req: *Request, res: *Response) anyerror!void {
    return try self.handler(ctx, req, res);
}

pub fn isMethodAllowed(self: *Route, method: std.http.Method) bool {
    for (self.methods) |m| {
        if (m == method) {
            return true;
        }
    }

    return false;
}

pub fn isPathMatch(self: *Route, path: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(self.path, "*")) {
        return true;
    }

    return std.ascii.eqlIgnoreCase(self.path, path);
}

pub fn isStaticRoute(self: *Route, path: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(self.path, "*")) {
        return true;
    }

    // not server root
    if (std.mem.eql(u8, "/", path) or std.mem.eql(u8, self.path, "") or std.mem.eql(u8, self.path, "/")) {
        return false;
    }

    var paths = std.mem.splitSequence(u8, path, "/");
    var ps = std.mem.splitSequence(u8, self.path, "/");
    if (std.ascii.eqlIgnoreCase(paths.next().?, ps.next().?)) {
        return true;
    }
    return std.ascii.eqlIgnoreCase(self.path, path);
}

pub fn isMatch(self: *Route, method: std.http.Method, path: []const u8) bool {
    if (self.isPathMatch(path) and self.isMethodAllowed(method)) {
        return true;
    }

    return false;
}

pub fn use(self: *Route, middleware: Middleware) anyerror!void {
    _ = middleware;
    _ = self;
}
