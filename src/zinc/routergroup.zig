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
    // Use arena allocator to avoid memory leaks
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const result = try arena.allocator().alloc(u8, self.prefix.len + path.len);
    @memcpy(result[0..self.prefix.len], self.prefix);
    @memcpy(result[self.prefix.len..], path);

    // Copy to main allocator to return
    const owned = try self.allocator.dupe(u8, result);
    return owned;
}

/// Create a new RouterGroup.
pub fn group(self: *Self, prefix: []const u8) anyerror!*RouterGroup {
    const group_path = try self.relativePath(prefix);
    defer self.allocator.free(group_path);
    return self.router.group(group_path);
}

pub fn deinit(self: *Self) void {
    // Free the copied prefix
    self.allocator.free(self.prefix);

    self.router = undefined;
    const allocator = self.allocator;
    allocator.destroy(self);
}

/// Create a new RouterGroup.
pub fn add(self: *RouterGroup, method: std.http.Method, target: []const u8, handler: HandlerFn) anyerror!void {
    const path = try self.relativePath(target);
    defer self.allocator.free(path);
    try self.router.add(method, path, handler);
}

/// Add a route with all HTTP methods.
pub fn any(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const methods = &[_]std.http.Method{ .GET, .POST, .PUT, .DELETE, .OPTIONS, .HEAD, .PATCH, .CONNECT, .TRACE };
    for (methods) |method| {
        const path = try self.relativePath(target);
        defer self.allocator.free(path);
        try self.router.add(method, path, handler);
    }
}

/// Add a route with any method.
pub fn addAny(self: *RouterGroup, methods: []const std.http.Method, target: []const u8, handler: HandlerFn) anyerror!void {
    for (methods) |method| {
        const path = try self.relativePath(target);
        defer self.allocator.free(path);
        try self.router.add(method, path, handler);
    }
}

/// Add a route with the GET method.
pub fn get(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const group_path = try self.relativePath(target);
    defer self.allocator.free(group_path);
    try self.router.get(group_path, handler);
}

/// Add a route with the POST method.
pub fn post(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const path = try self.relativePath(target);
    defer self.allocator.free(path);
    try self.router.post(path, handler);
}

/// Add a route with the PUT method.
pub fn put(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const path = try self.relativePath(target);
    defer self.allocator.free(path);
    try self.router.put(path, handler);
}

/// Add a route with DELETE method.
pub fn delete(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const path = try self.relativePath(target);
    defer self.allocator.free(path);
    try self.router.delete(path, handler);
}

/// Add a route that matches all HTTP methods.
pub fn patch(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const path = try self.relativePath(target);
    defer self.allocator.free(path);
    try self.router.patch(path, handler);
}

/// Add a route with the OPTIONS method.
pub fn options(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const path = try self.relativePath(target);
    defer self.allocator.free(path);
    try self.router.options(path, handler);
}

/// Add a route for the HEAD method.
pub fn head(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const path = try self.relativePath(target);
    defer self.allocator.free(path);
    try self.router.head(path, handler);
}

/// Add a route for the CONNECT method.
pub fn connect(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const path = try self.relativePath(target);
    defer self.allocator.free(path);
    try self.router.connect(path, handler);
}

/// Add a route for the TRACE method.
pub fn trace(self: *RouterGroup, target: []const u8, handler: HandlerFn) anyerror!void {
    const path = try self.relativePath(target);
    defer self.allocator.free(path);
    try self.router.trace(path, handler);
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
