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

middlewares: std.ArrayList(HandlerFn) = std.ArrayList(HandlerFn).init(page_allocator),

route_tree: *RouteTree = undefined,

pub fn init(self: Self) Router {
    const root = RouteTree.create(.{ .allocator = self.allocator }) catch unreachable;
    return .{
        .allocator = self.allocator,
        .middlewares = std.ArrayList(HandlerFn).init(self.allocator),
        .route_tree = root,
    };
}

pub fn deinit(self: *Self) void {
    self.middlewares.deinit();
    self.route_tree.destroy();
}

pub fn handleContext(self: *Self, ctx: *Context) anyerror!void {
    try self.prepareContext(ctx);
    try ctx.doRequest();
}

pub fn prepareContext(self: *Self, ctx: *Context) anyerror!void {
    const route = try self.getRoute(ctx.request.method, ctx.request.target);
    var items: []const HandlerFn = undefined;
    items = try route.handlers.toOwnedSlice();
    try ctx.handlers.appendSlice(items);
    try ctx.handlersProcess();
}

/// Return routes.
pub fn getRoutes(self: *Self) std.ArrayList(Route) {
    const rootTree = self.route_tree.getRoot().?;
    return rootTree.getCurrentTreeRoutes();
}

pub fn getRootTree(self: *Self) *RouteTree {
    return self.route_tree.getRoot().?;
}

pub fn add(self: *Self, method: std.http.Method, path: []const u8, handler: anytype) anyerror!void {
    _ = self.getRoute(method, path) catch {
        const route = Route.create(path, method, handler);
        try self.addRoute(route);
    };

    try self.rebuild();
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
    const path: []const u8 = url_target.path;

    const rTree = try self.route_tree.insert(path);
    try rTree.routes.append(route);
}

pub fn addRoute(self: *Self, route: Route) anyerror!void {
    try self.insertRouteToRouteTree(route);
    // try self.routes.append(route);
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

fn getRouteTree(self: *Self, target: []const u8) anyerror!*RouteTree {
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

    if (rTree.routes.items.len == 0) return Route.RouteError.NotFound;
    for (rTree.routes.items) |*route| {
        if (route.isMethodAllowed(method)) {
            // if (route.handlers.items.len == 0) return Route.RouteError.HandlersEmpty;
            return route;
        }
    }

    return Route.RouteError.MethodNotAllowed;
}

pub fn use(self: *Self, handler: []const HandlerFn) anyerror!void {
    try self.middlewares.appendSlice(handler);
    try self.rebuild();
}

/// Rebuild all routes.
pub fn rebuild(self: *Self) anyerror!void {
    const rootTree = self.route_tree.getRoot().?;
    try rootTree.use(self.middlewares.items);
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

    if (std.mem.eql(u8, relativePath, "")) return error.Empty;

    if (std.mem.eql(u8, filepath, "") or std.mem.eql(u8, filepath, "/")) return error.AccessDenied;

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

pub fn printRouter(self: *Self) void {
    const rootTree = self.getRootTree();
    rootTree.print(1);
}
