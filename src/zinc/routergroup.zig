const std = @import("std");
const heap = std.heap;
const page_allocator = heap.page_allocator;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const print = std.debug.print;

const zinc = @import("../zinc.zig");

const Context = zinc.Context;
const Request = zinc.Request;
const Response = zinc.Response;
const Route = zinc.Route;
const HandlerFn = zinc.HandlerFn;
const Router = zinc.Router;

pub const RouterGroup = @This();
const Self = @This();

allocator: Allocator = page_allocator,
prefix: []const u8 = "",
root: bool = false,
Handlers: ArrayList(HandlerFn) = ArrayList(HandlerFn).init(page_allocator),
router: *Router = undefined,
fn relativePath(self: RouterGroup, path: []const u8) []const u8 {
    if (self.root) {
        return self.prefix;
    }
    const prefix_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, path });
    return prefix_path;
}

pub fn add(self: *RouterGroup, method: std.http.Method, target: []const u8, handler: HandlerFn) anyerror!void {
    if (self.root) {
        try self.router.add(method, target, handler);
        return;
    }
    try self.router.add(method, try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
}

pub fn any(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const methods = &[_]std.http.Method{ .GET, .POST, .PUT, .DELETE, .OPTIONS, .HEAD, .PATCH, .CONNECT, .TRACE };
    if (self.root) {
        for (methods) |method| {
            try self.router.add(method, target, handler);
        }
        return;
    }
    for (methods) |method| {
        try self.router.add(method, try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
    }
}

pub fn addAny(self: *RouterGroup, methods: []const std.http.Method, target: []const u8, handler: HandlerFn) anyerror!void {
    if (self.root) {
        for (methods) |method| {
            try self.router.add(method, target, handler);
        }
        return;
    }
    for (methods) |method| {
        try self.router.add(method, try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
    }
}

pub fn get(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.get(try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
}

pub fn post(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.post(try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
}

pub fn put(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.put(try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
}

pub fn delete(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.delete(try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
}

pub fn patch(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.patch(try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
}

pub fn options(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.options(try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
}

pub fn head(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.head(try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
}

pub fn connect(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.connect(try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
}

pub fn trace(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.trace(try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, target }), handler);
}

pub fn use(self: *RouterGroup, handler: HandlerFn) anyerror!void {
    if (self.root) {
        try self.router.use(handler);
        return;
    }
    try self.router.use(handler);
}

// pub fn getRoutes(self: *RouterGroup) []Route {
//     return self.router.getRoutes();
// }

/// Return routes.
pub fn getRoutes(self: *RouterGroup) std.ArrayList(Route) {
    // return self.routes;
    return self.router.getRoutes();
}
