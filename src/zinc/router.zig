const std = @import("std");
const Allocator = std.mem.Allocator;
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

allocator: Allocator = undefined,

middlewares: std.ArrayList(HandlerFn) = undefined,

route_tree: *RouteTree = undefined,

pub fn init(self: Self) anyerror!*Router {
    const r = try self.allocator.create(Router);
    errdefer self.allocator.destroy(r);
    r.* = .{
        .allocator = self.allocator,
        .middlewares = std.ArrayList(HandlerFn).init(self.allocator),
        .route_tree = try RouteTree.init(.{
            .value = "/",
            .full_path = "/",
            .allocator = self.allocator,
            .children = std.StringHashMap(*RouteTree).init(self.allocator),
            .routes = std.ArrayList(*Route).init(self.allocator),
        }),
    };
    return r;
}

pub fn deinit(self: *Self) void {
    self.middlewares.deinit();
    self.route_tree.destroyTrieTree();

    self.allocator.destroy(self);
}

pub fn handleContext(self: *Self, ctx: *Context) anyerror!void {
    try self.prepareContext(ctx);
    try ctx.doRequest();
}

pub fn prepareContext(self: *Self, ctx: *Context) anyerror!void {
    const route = try self.getRoute(ctx.request.method, ctx.request.target);
    try route.handle(ctx);

    // // TODO, COPY HANDLERS TO CTX
    // ctx.handlers = route.handlers;
    // try ctx.handlersProcess();
}

/// Return routes.
/// Make sure to call `routes.deinit()` after using it.
pub fn getRoutes(self: *Self) std.ArrayList(*Route) {
    return self.route_tree.getCurrentTreeRoutes();
}

pub fn add(self: *Self, method: std.http.Method, path: []const u8, handler: HandlerFn) anyerror!void {
    _ = self.getRoute(method, path) catch {
        var handlers = std.ArrayList(HandlerFn).init(self.allocator);
        defer handlers.deinit();
        try handlers.appendSlice(self.middlewares.items);
        try handlers.append(handler);

        const route = try Route.create(self.allocator, path, method, handlers.items);
        try self.addRoute(route);
    };

    // try self.rebuild();
}

pub fn addAny(self: *Self, http_methods: []const std.http.Method, path: []const u8, handler: HandlerFn) anyerror!void {
    for (http_methods) |method| {
        try self.add(method, path, handler);
    }
}

pub fn any(self: *Self, path: []const u8, handler: HandlerFn) anyerror!void {
    for (self.methods) |method| {
        try self.add(method, path, handler);
    }
}

fn insertRouteToRouteTree(self: *Self, route: *Route) anyerror!void {
    var url = URL.init(.{ .allocator = self.allocator });
    defer url.deinit();

    const url_target = try url.parseUrl(route.path);
    const path: []const u8 = url_target.path;

    var rTree = try self.route_tree.insert(path);
    if (!rTree.isRouteExist(route)) {
        try rTree.routes.?.append(route);
    }
}

pub fn addRoute(self: *Self, route: *Route) anyerror!void {
    try self.insertRouteToRouteTree(route);
}

pub fn get(self: *Self, path: []const u8, handler: HandlerFn) anyerror!void {
    try self.add(.GET, path, handler);
}
pub fn post(self: *Self, path: []const u8, handler: HandlerFn) anyerror!void {
    try self.add(.POST, path, handler);
}
pub fn put(self: *Self, path: []const u8, handler: HandlerFn) anyerror!void {
    try self.add(.PUT, path, handler);
}
pub fn delete(self: *Self, path: []const u8, handler: HandlerFn) anyerror!void {
    try self.add(.DELETE, path, handler);
}
pub fn patch(self: *Self, path: []const u8, handler: HandlerFn) anyerror!void {
    try self.add(.PATCH, path, handler);
}
pub fn options(self: *Self, path: []const u8, handler: HandlerFn) anyerror!void {
    try self.add(.OPTIONS, path, handler);
}
pub fn head(self: *Self, path: []const u8, handler: HandlerFn) anyerror!void {
    try self.add(.HEAD, path, handler);
}
pub fn connect(self: *Self, path: []const u8, handler: HandlerFn) anyerror!void {
    try self.add(.CONNECT, path, handler);
}
pub fn trace(self: *Self, path: []const u8, handler: HandlerFn) anyerror!void {
    try self.add(.TRACE, path, handler);
}

fn getRouteTree(self: *Self, target: []const u8) anyerror!*RouteTree {
    var url = URL.init(.{ .allocator = self.allocator });
    defer url.deinit();

    const url_target = try url.parseUrl(target);
    const path = url_target.path;

    if (self.route_tree.find(path)) |f| return f;

    return error.NotFound;
}

pub fn getRoute(self: *Self, method: std.http.Method, target: []const u8) anyerror!*Route {
    var url = URL.init(.{ .allocator = self.allocator });
    defer url.deinit();

    const url_target = try url.parseUrl(target);

    const path: []const u8 = url_target.path;

    const rTree = try self.getRouteTree(path);

    if (rTree.routes) |*routes| {
        if (routes.items.len == 0) {
            return Route.RouteError.NotFound;
        }

        // If there is only one route and the path is empty, return NotFound.
        if (routes.items.len == 1) {
            if (std.mem.eql(u8, routes.items[0].path, "")) {
                return Route.RouteError.NotFound;
            }
        }

        for (routes.items) |r| {
            if (r.method == method) {
                return r;
            }
        }
        return Route.RouteError.MethodNotAllowed;
    }

    return Route.RouteError.NotFound;
}

pub fn use(self: *Self, handler: []const HandlerFn) anyerror!void {
    try self.middlewares.appendSlice(handler);
    try self.rebuild();
}

/// Rebuild all routes.
pub fn rebuild(self: *Self) anyerror!void {
    // Nothing to rebuild if there are no middlewares.
    if (self.middlewares.items.len == 0) return;

    try self.route_tree.use(self.middlewares.items);
}

pub fn group(self: *Self, prefix: []const u8) anyerror!*RouterGroup {
    const router_group = try self.allocator.create(RouterGroup);
    router_group.* = .{
        .allocator = self.allocator,
        .router = self,
        .prefix = prefix,
        .root = true,
    };
    errdefer self.allocator.destroy(router_group);

    return router_group;
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
    self.route_tree.print(0);
}
