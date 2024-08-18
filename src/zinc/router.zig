const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const page_allocator = heap.page_allocator;
const print = std.debug.print;

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

fn setNotFound(self: *Self, handler: anytype) anyerror!void {
    try self.addRoute(Route.get("*", handler));
}

fn setMethodNotAllowed(self: *Self, handler: anytype) anyerror!void {
    try self.addRoute(Route.get("*", handler));
}

pub fn add(self: *Self, methods: []const std.http.Method, path: []const u8, handler: anytype) anyerror!void {
    try self.addRoute(Route{
        .methods = methods,
        .path = path,
        .handler = handler,
    });
}

pub fn get(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.addRoute(Route.get(path, handler));
}
pub fn post(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.addRoute(Route.post(path, handler));
}
pub fn put(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.addRoute(Route.put(path, handler));
}
pub fn delete(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.addRoute(Route.delete(path, handler));
}
pub fn patch(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.addRoute(Route.patch(path, handler));
}
pub fn options(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.addRoute(Route.options(path, handler));
}
pub fn head(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.addRoute(Route.head(path, handler));
}
pub fn connect(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.addRoute(Route.connect(path, handler));
}
pub fn trace(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.addRoute(Route.trace(path, handler));
}

pub fn addRoute(self: *Self, route: Route) anyerror!void {
    try self.routes.append(route);
}

pub fn matchRoute(self: *Self, method: std.http.Method, path: []const u8) anyerror!*Route {
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

pub fn use(self: *Self, middleware: Middleware) anyerror!void {
    const routes = self.routes.items;

    for (routes) |*route| {
        try route.use(middleware);
    }
}

pub fn group(self: *Self, prefix: []const u8, handler: anytype) anyerror!RouterGroup {
    self.add(&.{}, prefix, handler) catch |err| {
        std.debug.panic("Failed to add route: {any}", .{err});
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
    if (std.mem.eql(relativePath, "") or std.mem.eql(filepath, "")) {
        return std.debug.panic("Invalid static file path: {s} {s}", .{ relativePath, filepath });
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
            return std.debug.panic("URL parameters can not be used when serving a static file: {s}", .{relativePath});
        }
    }

    try self.get(relativePath, handler);
    try self.head(relativePath, handler);
}
