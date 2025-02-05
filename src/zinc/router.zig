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

catchers: ?*Catchers = undefined,

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
        .catchers = try Catchers.init(self.allocator),
    };
    return r;
}

pub fn deinit(self: *Self) void {
    self.middlewares.deinit();
    self.route_tree.destroyTrieTree();
    if (self.catchers != null) {
        self.catchers.?.deinit();
    }

    self.allocator.destroy(self);
}

pub fn handleContext(self: *Self, ctx: *Context) anyerror!void {
    try self.prepareContext(ctx);
    try ctx.doRequest();
}
// pub fn handleConn(self: *Self, allocator: std.mem.Allocator, conn: std.net.Stream, read_buffer: []const u8) anyerror!void {
pub fn handleConn(self: *Self, allocator: std.mem.Allocator, conn: std.posix.socket_t, read_buffer: []u8) anyerror!void {
    var parser = Router.Parser.init(read_buffer);
    _ = try parser.parse();
    const req_method = parser.method;
    const req_target = parser.target;

    // TODO too slow, need to optimize
    const req = try Request.init(.{ .target = req_target, .method = req_method, .allocator = allocator });
    const res = try Response.init(.{ .conn = conn, .allocator = allocator });

    const ctx = try Context.init(.{ .request = req, .response = res, .allocator = allocator });
    defer ctx.destroy();

    const match_route = self.getRoute(req_method, req_target) catch |err| {
        try self.handleError(err, ctx);
        try ctx.doRequest();
        return;
    };
    defer {
        if (!ctx.response.isKeepAlive()) {
            std.posix.close(conn);
        }
    }

    try match_route.handle(ctx);
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
