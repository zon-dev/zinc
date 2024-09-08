const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const page_allocator = heap.page_allocator;
const print = std.debug.print;
const URL = @import("url");

const zinc = @import("../zinc.zig");
const Context = zinc.Context;
const Request = zinc.Request;
const Response = zinc.Response;
const Route = zinc.Route;
const HandlerFn = zinc.HandlerFn;
const RouterGroup = zinc.RouterGroup;

const RouteTree = zinc.RouteTree;

pub const Router = @This();
const Self = @This();

methods: []const std.http.Method = &[_]std.http.Method{
    .GET,
    .POST,
    .PUT,
    .DELETE,
    .OPTIONS,
    .HEAD,
    .PATCH,
    .CONNECT,
    .TRACE,
},

allocator: Allocator = page_allocator,
routes: std.ArrayList(Route) = undefined,
middlewares: std.ArrayList(HandlerFn) = undefined,

route_tree: *RouteTree = undefined,

pub fn init(self: Self) Router {
    const root = RouteTree.create(.{ .allocator = self.allocator }) catch unreachable;
    return .{
        .allocator = self.allocator,
        .routes = std.ArrayList(Route).init(self.allocator),
        .middlewares = std.ArrayList(HandlerFn).init(self.allocator),
        .route_tree = root,
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

/// Rebuild all routes.
pub fn rebuild(self: *Self) !void {
    for (self.routes.items) |*route| {
        var chain = std.ArrayList(HandlerFn).init(std.heap.page_allocator);
        try chain.appendSlice(self.middlewares.items);
        try chain.appendSlice(route.handlers_chain.items);
        route.handlers_chain.clearAndFree();
        route.handlers_chain = chain;
    }
}

/// Return routes.
pub fn getRoutes(self: *Self) std.ArrayList(Route) {
    return self.routes;
}

pub fn add(self: *Self, method: std.http.Method, path: []const u8, handler: anytype) anyerror!void {
    if (self.routes.items.len != 0) {
        for (self.routes.items) |*route| {
            if (std.mem.eql(u8, route.path, path) and route.method == method) {
                for (self.middlewares.items) |middleware| {
                    if (!route.isHandlerExists(middleware)) {
                        try route.handlers_chain.append(middleware);
                        return;
                    }
                }

                if (!route.isHandlerExists(handler)) {
                    try route.handlers_chain.append(handler);
                    return;
                }

                return;
            }
        }
    }

    var route = Route.create(path, method, handler);
    try route.use(self.middlewares.items);
    try self.addRoute(route);
}

pub fn addAny(self: *Self, http_methods: []const std.http.Method, path: []const u8, handler: HandlerFn) anyerror!void {
    for (http_methods) |method| {
        try self.add(method, path, handler);
    }
}

pub fn any(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    for (self.methods) |method| {
        try self.add(method, path, handler);
    }
}

fn insertRouteToRouteTree(self: *Self, route: Route) anyerror!void {
    var url = URL.init(.{});
    const url_target = try url.parseUrl(route.path);
    const path = url_target.path;

    try self.route_tree.insert(path);
    const rTree = self.route_tree.find(path).?;
    rTree.route = route;
}

pub fn addRoute(self: *Self, route: Route) anyerror!void {
    try self.insertRouteToRouteTree(route);
    try self.routes.append(route);
}

pub fn get(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(.GET, path, handler);
}
pub fn post(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(.POST, path, handler);
}
pub fn put(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(.PUT, path, handler);
}
pub fn delete(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(.DELETE, path, handler);
}
pub fn patch(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(.PATCH, path, handler);
}
pub fn options(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(.OPTIONS, path, handler);
}
pub fn head(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(.HEAD, path, handler);
}
pub fn connect(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(.CONNECT, path, handler);
}
pub fn trace(self: *Self, path: []const u8, handler: anytype) anyerror!void {
    try self.add(.TRACE, path, handler);
}
pub fn matchRoute(self: *Self, method: std.http.Method, target: []const u8) anyerror!*Route {
    var err = Route.RouteError.NotFound;
    var url = URL.init(.{});
    const url_target = try url.parseUrl(target);
    const path = url_target.path;
    for (self.routes.items) |*route| {
        if (std.mem.eql(u8, path, "*")) {
            if (route.isMethodAllowed(method)) {
                return route;
            }
            err = Route.RouteError.MethodNotAllowed;
        }

        if (route.isPathMatch(path)) {
            if (route.isMethodAllowed(method)) {
                return route;
            }
            err = Route.RouteError.MethodNotAllowed;
        }

        // match static file
        if (route.isStaticRoute(path)) {
            if (route.isMethodAllowed(method)) {
                return route;
            }
            err = Route.RouteError.MethodNotAllowed;
        }
    }

    return err;
}

pub fn getRouteTree(self: *Self, target: []const u8) anyerror!*RouteTree {
    var url = URL.init(.{});
    const url_target = try url.parseUrl(target);
    const path = url_target.path;

    const rTree = self.route_tree.find(path);
    if (rTree == null) return Route.RouteError.NotFound;
    return rTree.?;
}

pub fn getRoute(self: *Self, method: std.http.Method, target: []const u8) anyerror!*Route {
    var url = URL.init(.{});
    const url_target = try url.parseUrl(target);
    const path = url_target.path;

    const rTree = try self.getRouteTree(path);
    if (rTree.route.method == method) return &rTree.route;

    return Route.RouteError.MethodNotAllowed;
}

pub fn use(self: *Self, handler: anytype) anyerror!void {
    for (self.routes.items) |*route| {
        try route.use(handler);
    }
}

pub fn group(self: *Self, prefix: []const u8) anyerror!RouterGroup {
    return RouterGroup{
        .router = self,
        .prefix = prefix,
        .root = true,
    };
}

pub inline fn static(self: *Self, relativePath: []const u8, filepath: []const u8) anyerror!void {
    try checkPath(filepath);

    if (std.mem.eql(u8, relativePath, "")) {
        return error.Empty;
    }

    if (std.mem.eql(u8, filepath, "") or std.mem.eql(u8, filepath, "/")) {
        return error.AccessDenied;
    }

    if (std.fs.path.basename(filepath).len == 0) {
        return self.staticDir(relativePath, filepath);
    }

    return self.staticFile(relativePath, filepath);
}

pub inline fn staticFile(self: *Self, target: []const u8, filepath: []const u8) anyerror!void {
    try checkPath(filepath);
    const H = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.file(filepath, .{});
        }
    };
    try self.get(target, H.handle);
    try self.head(target, H.handle);
}

pub inline fn staticDir(self: *Self, target: []const u8, filepath: []const u8) anyerror!void {
    try checkPath(filepath);
    const H = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.dir(filepath, .{});
        }
    };
    try self.get(target, H.handle);
    try self.head(target, H.handle);
}

fn staticFileHandler(self: *Self, relativePath: []const u8, handler: HandlerFn) anyerror!void {
    try checkPath(relativePath);

    try self.get(relativePath, handler);
    try self.head(relativePath, handler);
}

fn checkPath(path: []const u8) anyerror!void {
    for (path) |c| {
        if (c == '*' or c == ':') {
            return error.Unreachable;
        }
    }
}
