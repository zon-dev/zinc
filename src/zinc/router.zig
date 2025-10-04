const std = @import("std");
const Allocator = std.mem.Allocator;
const Head = std.http.Server.Request.Head;

const URL = @import("url");

const zinc = @import("../zinc.zig");
const Context = zinc.Context;
const Request = zinc.Request;
const Response = zinc.Response;
const Route = zinc.Route;
const HandlerFn = zinc.HandlerFn;
const RouterGroup = zinc.RouterGroup;

const RouteTree = zinc.RouteTree;

const Catchers = zinc.Catchers;

// Global static variable to store the current router instance
var current_router: ?*Router = null;

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

middlewares: std.array_list.Managed(HandlerFn) = undefined,

route_tree: *RouteTree = undefined,

catchers: ?*Catchers = undefined,

data: *anyopaque = undefined,

static_files: ?std.StringHashMap([]const u8) = null,
static_dirs: ?std.StringHashMap([]const u8) = null,

fn setData(self: Self, ptr: anytype) void {
    self.data = ptr;
}

pub fn init(self: Self) anyerror!*Router {
    const r = try self.allocator.create(Router);
    errdefer self.allocator.destroy(r);
    r.* = .{
        .allocator = self.allocator,
        .middlewares = std.array_list.Managed(HandlerFn).init(self.allocator),
        .route_tree = try RouteTree.init(.{
            .value = "/",
            .full_path = "/",
            .allocator = self.allocator,
            .children = std.StringHashMap(*RouteTree).init(self.allocator),
            .routes = std.array_list.Managed(*Route).init(self.allocator),
        }),
        .catchers = try Catchers.init(self.allocator),
        .data = self.data,
        .static_files = std.StringHashMap([]const u8).init(self.allocator),
        .static_dirs = std.StringHashMap([]const u8).init(self.allocator),
    };
    return r;
}

pub fn deinit(self: *Self) void {
    const allocator = self.allocator;

    self.middlewares.deinit();
    self.route_tree.destroyTrieTree();
    if (self.catchers != null) {
        self.catchers.?.deinit();
    }

    // 释放静态文件映射中的内存
    if (self.static_files) |*sf| {
        var it = sf.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        sf.deinit();
    }

    // 释放静态目录映射中的内存
    if (self.static_dirs) |*sd| {
        var it = sd.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        sd.deinit();
    }

    // Note: route_tree is destroyed by destroyTrieTree() above
    allocator.destroy(self);
}

pub fn handleContext(self: *Self, ctx: *Context) anyerror!void {
    try self.prepareContext(ctx);
    try ctx.doRequest();
}
// pub fn handleConn(self: *Self, allocator: std.mem.Allocator, conn: std.net.Stream, read_buffer: []const u8) anyerror!void {
pub fn handleConn(self: *Self, allocator: std.mem.Allocator, conn: std.posix.socket_t, read_buffer: []u8) anyerror!void {
    // Set global router variable for handler use
    current_router = self;
    defer current_router = null;

    var parser = Router.Parser.init(read_buffer);
    _ = try parser.parse();
    const req_method = parser.method;
    const req_target = parser.target;

    // Optimized: Create objects with minimal allocations
    const req = try Request.init(.{ .target = req_target, .method = req_method, .allocator = allocator });
    const res = try Response.init(.{ .conn = conn, .allocator = allocator });

    // Set Response's req_method field
    res.req_method = req_method;

    const ctx = try Context.init(.{ .request = req, .response = res, .allocator = allocator, .data = self.data });
    defer ctx.destroy();

    const match_route = self.getRoute(req_method, req_target) catch |err| {
        try self.handleError(err, ctx);
        try ctx.doRequest();
        return;
    };

    try match_route.handle(ctx);

    // Do not close connection here, let AIO handle it
    // The connection will be closed in handleReadCompletion based on keep-alive status
}

pub const Parser = struct {
    // GET / HTTP/1.1
    // Host: 0.0.0.0:5882
    buf: []u8,

    // position in buf that we've parsed up to
    pos: usize,

    len: usize,

    method: std.http.Method = undefined,

    target: []const u8 = undefined,

    pub fn init(buf: []u8) Parser {
        return Parser{ .buf = buf, .pos = 0, .len = buf.len };
    }

    pub fn parse(self: *Parser) !bool {
        _ = try self.parseMethod(self.buf);
        _ = try self.parseTarget(self.buf);
        return true;
    }

    fn parseMethod(self: *Parser, buffer: []u8) !bool {
        //
        const buf = buffer[self.pos..];

        const buf_len = buf.len;

        // Shortest method is only 3 characters (+1 trailing space), so
        // this seems like it should be: if (buf_len < 4)
        // But the longest method, OPTIONS, is 7 characters (+1 trailing space).
        // Now even if we have a short method, like "GET ", we'll eventually expect
        // a URL + protocol. The shorter valid line is: e.g. GET / HTTP/1.1
        // If buf_len < 8, we _might_ have a method, but we still need more data
        // and might as well break early.
        // If buf_len > = 8, then we can safely parse any (valid) method without
        // having to do any other bound-checking.
        if (buf_len < 8) return false;

        // this approach to matching method name comes from zhp
        switch (@as(u32, @bitCast(buf[0..4].*))) {
            asUint("GET ") => {
                self.pos = 4;
                self.method = .GET;
            },
            asUint("PUT ") => {
                self.pos = 4;
                self.method = .PUT;
            },
            asUint("POST") => {
                if (buf[4] != ' ') return error.UnknownMethod;
                self.pos = 5;
                self.method = .POST;
            },
            asUint("HEAD") => {
                if (buf[4] != ' ') return error.UnknownMethod;
                self.pos = 5;
                self.method = .HEAD;
            },
            asUint("PATC") => {
                if (buf[4] != 'H' or buf[5] != ' ') return error.UnknownMethod;
                self.pos = 6;
                self.method = .PATCH;
            },
            asUint("DELE") => {
                if (@as(u32, @bitCast(buf[3..7].*)) != asUint("ETE ")) return error.UnknownMethod;
                self.pos = 7;
                self.method = .DELETE;
            },
            asUint("OPTI") => {
                if (@as(u32, @bitCast(buf[4..8].*)) != asUint("ONS ")) return error.UnknownMethod;
                self.pos = 8;
                self.method = .OPTIONS;
            },
            asUint("CONN") => {
                if (@as(u32, @bitCast(buf[4..8].*)) != asUint("ECT ")) return error.UnknownMethod;
                self.pos = 8;
                self.method = .CONNECT;
            },
            else => {
                const space = std.mem.indexOfScalarPos(u8, buf, 0, ' ') orelse return error.UnknownMethod;
                if (space == 0) {
                    return error.UnknownMethod;
                }

                const candidate = buf[0..space];
                for (candidate) |c| {
                    if (c < 'A' or c > 'Z') {
                        return error.UnknownMethod;
                    }
                }

                // + 1 to skip the space
                self.pos = space + 1;
                // self.method = .OTHER;
                // self.method_string = candidate;
            },
        }
        return true;
    }

    fn parseTarget(self: *Parser, buffer: []u8) !bool {
        const buf = buffer[self.pos..];

        const buf_len = buf.len;
        if (buf_len == 0) return false;

        var len: usize = 0;
        switch (buf[0]) {
            '/' => {
                const end_index = std.mem.indexOfScalarPos(u8, buf[1..buf_len], 0, ' ') orelse return false;
                // +1 since we skipped the leading / in our indexOfScalar and +1 to consume the space
                len = end_index + 2;
                const url = buf[0 .. end_index + 1];
                // if (!Url.isValid(url)) return error.InvalidRequestTarget;
                self.target = url;
            },
            '*' => {
                if (buf_len == 1) return false;
                // Read never returns 0, so if we're here, buf.len >= 1
                if (buf[1] != ' ') return error.InvalidRequestTarget;
                len = 2;
                self.target = buf[0..1];
            },
            // TODO: Support absolute-form target (e.g. http://....)
            else => return error.InvalidRequestTarget,
        }

        self.pos += len;
        return true;
    }
};

/// converts ascii to unsigned int of appropriate size
fn asUint(comptime string: anytype) @Type(std.builtin.Type{
    .int = .{
        .bits = @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
        .signedness = .unsigned,
    },
}) {
    const byteLength = @bitSizeOf(@TypeOf(string.*)) / 8 - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}

const headInfo = struct {
    method: std.http.Method,
    target: []const u8,
};

inline fn int64(array: *const [8]u8) u64 {
    return @bitCast(array.*);
}

/// Get the catcher by status.
fn getCatcher(self: *Self, status: std.http.Status) ?HandlerFn {
    return self.catchers.?.get(status);
}

/// Set the catcher by status.
pub fn setCatcher(self: *Self, status: std.http.Status, handler: HandlerFn) anyerror!void {
    try self.catchers.?.put(status, handler);
}

fn handleError(self: *Self, err: anyerror, ctx: *Context) anyerror!void {
    switch (err) {
        Route.RouteError.NotFound => {
            if (self.getCatcher(.not_found)) |notFoundHande| {
                try notFoundHande(ctx);
            } else return err;
        },
        Route.RouteError.MethodNotAllowed => {
            if (self.getCatcher(.method_not_allowed)) |methodNotAllowedHande| {
                try methodNotAllowedHande(ctx);
            } else return err;
        },
        else => |e| return e,
    }
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
pub fn getRoutes(self: *Self) std.array_list.Managed(*Route) {
    return self.route_tree.getCurrentTreeRoutes();
}

pub fn add(self: *Self, method: std.http.Method, path: []const u8, handler: HandlerFn) anyerror!void {
    _ = self.getRoute(method, path) catch {
        var handlers = std.array_list.Managed(HandlerFn).init(self.allocator);
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
    } else {
        // If route already exists, we need to properly free the duplicate route
        // But we should not call route.deinit() here because route might already be in the tree
        // Instead, we should free the route's path if it's owned
        if (route.path_owned) {
            self.allocator.free(route.path);
        }
        self.allocator.destroy(route);
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

            // enable for CORS
            if (r.method == .GET and method == .OPTIONS) {
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
    errdefer self.allocator.destroy(router_group);

    // Copy the prefix string to avoid memory leaks
    const prefix_copy = try self.allocator.dupe(u8, prefix);
    errdefer self.allocator.free(prefix_copy);

    router_group.* = .{
        .allocator = self.allocator,
        .router = self,
        .prefix = prefix_copy,
        .root = true,
    };

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

pub inline fn staticFile(self: *Self, url: []const u8, filepath: []const u8) anyerror!void {
    try checkPath(url); // 检查 URL 路径而不是文件路径

    // Ensure static_files map is initialized
    if (self.static_files == null) {
        self.static_files = std.StringHashMap([]const u8).init(self.allocator);
    }

    // Check if URL already exists and free the old filepath if it does
    if (self.static_files.?.getPtr(url)) |existing_filepath| {
        self.allocator.free(existing_filepath.*);
    }

    // copy filepath string to avoid memory issues
    const filepath_copy = try self.allocator.dupe(u8, filepath);

    // store URL to filepath mapping
    try self.static_files.?.put(url, filepath_copy);

    // register GET and HEAD handlers
    try self.get(url, staticFileHandler);
    try self.head(url, staticFileHandler);
}

pub inline fn staticDir(self: *Self, url: []const u8, dirpath: []const u8) anyerror!void {
    try checkPath(url); // 检查 URL 路径而不是目录路径

    // 确保 static_dirs map 已初始化
    if (self.static_dirs == null) {
        self.static_dirs = std.StringHashMap([]const u8).init(self.allocator);
    }

    // Check if URL already exists and free the old dirpath if it does
    if (self.static_dirs.?.getPtr(url)) |existing_dirpath| {
        self.allocator.free(existing_dirpath.*);
    }

    // Copy dirpath string to avoid memory issues
    const dirpath_copy = try self.allocator.dupe(u8, dirpath);

    // Store URL to dirpath mapping
    try self.static_dirs.?.put(url, dirpath_copy);

    // Register GET and HEAD handlers
    try self.get(url, staticDirHandler);
    try self.head(url, staticDirHandler);
}

// Static file handler - find file path through global mapping
fn staticFileHandler(ctx: *Context) anyerror!void {
    const router = current_router orelse return error.RouterNotSet;
    const filepath = router.static_files.?.get(ctx.request.target) orelse return error.NotFound;
    try ctx.file(filepath, .{});
}

// Static directory handler - find directory path through global mapping
fn staticDirHandler(ctx: *Context) anyerror!void {
    const router = current_router orelse return error.RouterNotSet;
    const dirpath = router.static_dirs.?.get(ctx.request.target) orelse return error.NotFound;
    try ctx.dir(dirpath, .{});
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
