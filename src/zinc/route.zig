const std = @import("std");
const HandlerFn = @import("handler.zig").HandlerFn;
// const HandleAction = @import("handler.zig").HandleAction;
const Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Route = @This();

methods: []const std.http.Method = &.{},

path: []const u8,

handler: HandlerFn,

pub fn init(methods: []const std.http.Method, comptime path: []const u8, comptime handler: anytype) Route {
    return Route{
        .methods = methods,
        .path = path,
        .handler = handler,
    };
}

pub fn match(self: *Route, method: std.http.Method, path: []const u8) bool {
    if (self.methods.len == 0) {
        if (std.ascii.eqlIgnoreCase(self.path, path)) {
            return true;
        }
    }

    if (!std.ascii.eqlIgnoreCase(self.path, path)) {
        return false;
    }

    for (self.methods) |m| {
        if (m == method) {
            return true;
        }
    }
    return false;
}

pub fn get(comptime path: []const u8, comptime handler: anytype) Route {
    return init(&.{.GET}, path, handler);
}

pub fn post(comptime path: []const u8, comptime handler: anytype) Route {
    return init(&.{.POST}, path, handler);
}
pub fn put(comptime path: []const u8, comptime handler: anytype) Route {
    return init(&.{.PUT}, path, handler);
}
pub fn delete(comptime path: []const u8, comptime handler: anytype) Route {
    return init(&.{.DELETE}, path, handler);
}
pub fn patch(comptime path: []const u8, comptime handler: anytype) Route {
    return init(&.{.PATCH}, path, handler);
}
pub fn options(comptime path: []const u8, comptime handler: anytype) Route {
    return init(&.{.OPTIONS}, path, handler);
}
pub fn head(comptime path: []const u8, comptime handler: anytype) Route {
    return init(&.{.HEAD}, path, handler);
}
pub fn connect(comptime path: []const u8, comptime handler: anytype) Route {
    return init(&.{.CONNECT}, path, handler);
}
pub fn trace(comptime path: []const u8, comptime handler: anytype) Route {
    return init(&.{.TRACE}, path, handler);
}

// pub fn add(self: *std.ArrayList(Route), comptime route: Route) anyerror!void {
//     return self.append(route);
// }

pub fn getPath(self: *Route) []const u8 {
    return self.path;
}

pub fn getHandler(self: *Route) HandlerFn {
    return &self.handler;
}

pub fn execute(self: *Route, ctx: *Context, req: *Request, res: *Response) anyerror!void {
    return &self.handler(ctx, req, res);
}
