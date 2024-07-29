const std = @import("std");
const HandlerFn = @import("handler.zig").HandlerFn;
const HandleAction = @import("handler.zig").HandleAction;
const Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Route = @This();

http_method: std.http.Method,

path: []const u8,

handler: *const fn (Context, Request, Response) anyerror!void,

pub fn new(http_method: std.http.Method, comptime path: []const u8, comptime handler: anytype )  Route {
    return Route{
        .http_method = http_method,
        .path = path,
        .handler = handler,
    };
}

pub fn get(comptime path: []const u8, comptime handler: anytype )  Route {
    return new(std.http.Method.GET, path, handler);
}

pub fn post(comptime path: []const u8, comptime handler: anytype )  Route {
    return new(std.http.Method.POST, path, handler);
}

pub fn getPath(self: *Route) []const u8 {
    return self.path;
}

pub fn getHandler(self: *Route) *const fn (Context, Request, Response) anyerror!void {
    return self.handler;
}

pub fn execute(self: *Route, context: *Context, request: *Request, response: *Response) anyerror!void {
    const handler = self.handler;
    return handler(context, request, response);
}