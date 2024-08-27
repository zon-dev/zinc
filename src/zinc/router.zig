const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const page_allocator = heap.page_allocator;
const print = std.debug.print;
const URL = @import("url");
const Context = @import("context.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");
const Route = @import("route.zig");
const Handler = @import("handler.zig");
const HandlerFn = Handler.HandlerFn;
const Middleware = @import("middleware.zig");

const RouterGroup = @import("routergroup.zig");

pub const Router = @This();
const Self = @This();

allocator: Allocator = page_allocator,
routes: std.ArrayList(Route) = std.ArrayList(Route).init(page_allocator),
// catchers: std.AutoHashMap(std.http.Status, HandlerFn) = std.AutoHashMap(std.http.Status, HandlerFn).init(std.heap.page_allocator),

pub fn init(self: Self) Router {
    return .{
        .allocator = self.allocator,
        .routes = self.routes,
    };
}

pub fn deinit(self: *Self) void {
    self.routes.deinit();
}

pub fn handleContext(self: *Self, ctx: Context) anyerror!void {
    const routes = self.routes.items;

    for (routes) |*route| {
        if (route.match(ctx.request.method, ctx.request.path)) {
            return try route.HandlerFn(ctx, ctx.request, ctx.response);
        }
    }
}

/// Return routes.
pub fn getRoutes(self: *Self) std.ArrayList(Route) {
    return self.routes;
}

fn setNotFound(self: *Self, handler: anytype) anyerror!void {
    try self.add(Route.get("*", handler));
}

fn setMethodNotAllowed(self: *Self, handler: anytype) anyerror!void {
    try self.add(Route.get("*", handler));
}

pub fn add(self: *Self, methods: []const std.http.Method, path: []const u8, handler: anytype) anyerror!void {
    for (self.routes.items) |*route| {
        if (route.isPathMatch(path)) {
            route.handlers_chain.append(handler) catch |err| {
                std.log.err("append handler error: {any}", .{err});
                return err;
            };
            return;
        }
    }
    try self.addRoute(Route.create(path, methods, handler));
}

pub fn addRoute(self: *Self, route: Route) anyerror!void {
    try self.routes.append(route);
}

pub fn get(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(&.{.GET}, path, handler);
}
pub fn post(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(&.{.POST}, path, handler);
}
pub fn put(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(&.{.PUT}, path, handler);
}
pub fn delete(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(&.{.DELETE}, path, handler);
}
pub fn patch(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(&.{.PATCH}, path, handler);
}
pub fn options(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(&.{.OPTIONS}, path, handler);
}
pub fn head(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(&.{.HEAD}, path, handler);
}
pub fn connect(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(&.{.CONNECT}, path, handler);
}
pub fn trace(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(&.{.TRACE}, path, handler);
}

// pub fn add(self: *Self, route: Route) anyerror!void {
//     try self.routes.append(route);
// }

pub fn matchRoute(self: *Self, method: std.http.Method, target: []const u8) anyerror!*Route {
    var url = URL.init(.{});
    const url_target = try url.parseUrl(target);
    const path = url_target.path;

    const routes = self.routes.items;

    for (routes) |*route| {
        if (route.isPathMatch(path)) {
            if (route.isMethodAllowed(method)) {
                return route;
            }
            return Route.RouteError.MethodNotAllowed;
        }

        // match static file
        if (route.isStaticRoute(path)) {
            if (route.isMethodAllowed(method)) {
                return route;
            }
            return Route.RouteError.MethodNotAllowed;
        }
    }

    return Route.RouteError.NotFound;
}

pub fn use(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    const routes = self.routes.items;

    for (routes) |*route| {
        if (route.isPathMatch(path)) {
            try route.use(handler);
        }
    }
}

pub fn group(self: *Self, prefix: []const u8, handler: anytype) anyerror!RouterGroup {
    self.add(&.{}, prefix, handler) catch |err| {
        return err;
    };

    const g = RouterGroup{
        .router = self,
        .prefix = prefix,
        .root = true,
    };

    return g;
}

pub fn static(self: *Self, relativePath: []const u8, filepath: []const u8) anyerror!void {
    _ = self;
    if (std.mem.eql(u8, relativePath, "") or std.mem.eql(u8, filepath, "")) {
        return error.Empty;
    }
}

pub fn staticFile(self: *Self, target: []const u8, filepath: []const u8) anyerror!void {
    _ = self;
    _ = target;
    _ = filepath;
}

fn staticFileHandler(self: *Self, relativePath: []const u8, handler: HandlerFn) anyerror!void {
    for (relativePath) |c| {
        if (c == '*' or c == ':') {
            return error.Unreachable;
        }
    }

    try self.get(relativePath, handler);
    try self.head(relativePath, handler);
}
