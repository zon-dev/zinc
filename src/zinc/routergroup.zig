const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const zinc = @import("../zinc.zig");

const Context = zinc.Context;
const Request = zinc.Request;
const Response = zinc.Response;
const Route = zinc.Route;
const HandlerFn = zinc.HandlerFn;
const Router = zinc.Router;

pub const RouterGroup = @This();
const Self = @This();

const RouteTree = zinc.RouteTree;

allocator: Allocator,
router: *Router,

prefix: []const u8,

root: bool = false,

fn relativePath(self: *RouterGroup, path: []const u8) anyerror![]const u8 {
    var slice = std.ArrayList(u8).init(self.allocator);
    defer slice.deinit();

    try slice.appendSlice(self.prefix);
    try slice.appendSlice(path);

    return try slice.toOwnedSlice();
}

/// Create a new RouterGroup.
pub fn group(self: *Self, prefix: []const u8) anyerror!*RouterGroup {
    const group_path = try self.relativePath(prefix);

    return self.router.group(group_path);
}

pub fn deinit(self: *Self) void {
    // _ = self;
    self.allocator.destroy(self);
}

/// Create a new RouterGroup.
pub fn add(self: *RouterGroup, method: std.http.Method, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.add(method, try self.relativePath(target), handler);
}

/// Add a route with all HTTP methods.
pub fn any(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const methods = &[_]std.http.Method{ .GET, .POST, .PUT, .DELETE, .OPTIONS, .HEAD, .PATCH, .CONNECT, .TRACE };
    for (methods) |method| {
        try self.router.add(method, try self.relativePath(target), handler);
    }
}

/// Add a route with any method.
pub fn addAny(self: *RouterGroup, methods: []const std.http.Method, target: []const u8, handler: HandlerFn) anyerror!void {
    for (methods) |method| {
        try self.router.add(method, try self.relativePath(target), handler);
    }
}

/// Add a route with the GET method.
pub fn get(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const group_path = try self.relativePath(target);
    try self.router.get(group_path, handler);
}

/// Add a route with the POST method.
pub fn post(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.post(try self.relativePath(target), handler);
}

/// Add a route with the PUT method.
pub fn put(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.put(try self.relativePath(target), handler);
}

/// Add a route with DELETE method.
pub fn delete(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.delete(try self.relativePath(target), handler);
}

/// Add a route that matches all HTTP methods.
pub fn patch(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.patch(try self.relativePath(target), handler);
}

/// Add a route with the OPTIONS method.
pub fn options(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.options(try self.relativePath(target), handler);
}

/// Add a route for the HEAD method.
pub fn head(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.head(try self.relativePath(target), handler);
}

/// Add a route for the CONNECT method.
pub fn connect(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.connect(try self.relativePath(target), handler);
}

/// Add a route for the TRACE method.
pub fn trace(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    try self.router.trace(try self.relativePath(target), handler);
}

/// Add middleware to the route.
pub fn use(self: *RouterGroup, handler: HandlerFn) anyerror!void {
    try self.router.use(handler);
}

/// Return routes.
pub fn getRoutes(self: *RouterGroup) std.ArrayList(Route) {
    return self.router.getRoutes();
}

pub fn getRootTree(self: *Self) *RouteTree {
    return self.router.route_tree.getRoot().?;
}
