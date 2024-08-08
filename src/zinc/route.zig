const std = @import("std");
const HandlerFn = @import("handler.zig").HandlerFn;
// const HandleAction = @import("handler.zig").HandleAction;
const Context = @import("context.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");

const logger = @import("logger.zig").init(.{});

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

handler: HandlerFn = undefined,

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
    if (std.ascii.eqlIgnoreCase(self.path, path)) {
        for (self.methods) |m| {
            if (m == method) {
                return self;
            }
        }
        return RouteError.MethodNotAllowed;
    }

    return RouteError.NotFound;
}

test "route matching and redirection" {
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

pub fn get(comptime path: []const u8, comptime handler: anytype) Route {
    return init(.{ .methods = &.{.GET}, .path = path, .handler = handler });
}

pub fn post(comptime path: []const u8, comptime handler: anytype) Route {
    return init(.{ .methods = &.{.POST}, .path = path, .handler = handler });
}
pub fn put(comptime path: []const u8, comptime handler: anytype) Route {
    return init(.{ .methods = &.{.PUT}, .path = path, .handler = handler });
}
pub fn delete(comptime path: []const u8, comptime handler: anytype) Route {
    return init(.{ .methods = &.{.DELETE}, .path = path, .handler = handler });
}
pub fn patch(comptime path: []const u8, comptime handler: anytype) Route {
    return init(.{ .methods = &.{.PATCH}, .path = path, .handler = handler });
}
pub fn options(comptime path: []const u8, comptime handler: anytype) Route {
    return init(.{ .methods = &.{.OPTIONS}, .path = path, .handler = handler });
}
pub fn head(comptime path: []const u8, comptime handler: anytype) Route {
    return init(.{ .methods = &.{.HEAD}, .path = path, .handler = handler });
}
pub fn connect(comptime path: []const u8, comptime handler: anytype) Route {
    return init(.{ .methods = &.{.CONNECT}, .path = path, .handler = handler });
}
pub fn trace(comptime path: []const u8, comptime handler: anytype) Route {
    return init(.{ .methods = &.{.TRACE}, .path = path, .handler = handler });
}

pub fn getPath(self: *Route) []const u8 {
    return self.path;
}

pub fn getHandler(self: *Route) HandlerFn {
    return &self.handler;
}

pub fn handle(self: *Route, ctx: *Context, req: *Request, res: *Response) anyerror!void {
    return try self.handler(ctx, req, res);
}
