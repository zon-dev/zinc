const std = @import("std");
const print = std.debug.print;

const HandlerFn = @import("handler.zig").HandlerFn;
const Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Route = @import("route.zig");

pub const Router = @This();
const Self = @This();

allocator: std.mem.Allocator = std.heap.page_allocator,
routes: std.ArrayList(Route) = std.ArrayList(Route).init(std.heap.page_allocator),

pub fn init(self: Self) Router {
    return .{
        .allocator = self.allocator,
        .routes = self.routes,
    };
}

pub fn handleContext(self: *Self, ctx: Context) void {
    const routes = self.routes.items;

    for (routes) |*route| {
        if (route.match(ctx.request.method, ctx.request.path)) {
            try route.HandlerFn(ctx, ctx.request, ctx.response);
            return;
        }
    }
}

/// Return routes.
pub fn getRoutes(self: *Self) std.ArrayList(Route) {
    return self.routes;
}

pub fn setNotFound(self: *Self, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route.get("*", handler));
}

pub fn add(self: *Self, comptime methods: []const std.http.Method, comptime path: []const u8, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route{
        .methods = methods,
        .path = path,
        .handler = handler,
    });
}

pub fn get(self: *Self, comptime path: []const u8, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route.get(path, handler));
}
pub fn post(self: *Self, comptime path: []const u8, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route.post(path, handler));
}
pub fn put(self: *Self, comptime path: []const u8, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route.put(path, handler));
}
pub fn delete(self: *Self, comptime path: []const u8, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route.delete(path, handler));
}
pub fn patch(self: *Self, comptime path: []const u8, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route.patch(path, handler));
}
pub fn options(self: *Self, comptime path: []const u8, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route.options(path, handler));
}
pub fn head(self: *Self, comptime path: []const u8, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route.head(path, handler));
}
pub fn connect(self: *Self, comptime path: []const u8, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route.connect(path, handler));
}
pub fn trace(self: *Self, comptime path: []const u8, comptime handler: anytype) anyerror!void {
    try self.addRoute(Route.trace(path, handler));
}

pub fn addRoute(self: *Self, route: Route) anyerror!void {
    try self.routes.append(route);
}

pub fn matchRoute(self: *Self, method: std.http.Method, path: []const u8) ?*Route {
    const routes = self.routes.items;

    for (routes) |*route| {
        if (route.match(method, path)) {
            return route;
        }
    }

    return null;
}
