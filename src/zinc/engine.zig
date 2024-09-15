const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const proto = http.protocol;
const Server = http.Server;
const Allocator = std.mem.Allocator;
const Condition = std.Thread.Condition;

const URL = @import("url");

const zinc = @import("../zinc.zig");
const Router = zinc.Router;
const Route = zinc.Route;
const RouterGroup = zinc.RouterGroup;
const RouteTree = zinc.RouteTree;
const Context = zinc.Context;
const Request = zinc.Request;
const Response = zinc.Response;
const Config = zinc.Config;
const HandlerFn = zinc.HandlerFn;
const Catchers = zinc.Catchers;

const default_response = @import("default_response.zig");

pub const Engine = @This();
const Self = @This();

allocator: Allocator = undefined,

net_server: std.net.Server,

// threads
threads: std.ArrayList(std.Thread) = undefined,
stopping: std.Thread.ResetEvent = .{},
stopped: std.Thread.ResetEvent = .{},
mutex: std.Thread.Mutex = .{},

/// see at https://github.com/ziglang/zig/blob/master/lib/std/Thread/Condition.zig
cond: Condition = .{},
completed: Condition = .{},
num_threads: usize = 0,
spawn_count: usize = 0,

stack_size: usize = undefined,

// buffer len
read_buffer_len: usize = undefined,
header_buffer_len: usize = undefined,
body_buffer_len: usize = undefined,

// options
router: ?*Router = undefined,
catchers: ?*Catchers = undefined,
middlewares: ?std.ArrayList(HandlerFn) = undefined,

/// Create a new engine.
fn create(conf: Config.Engine) anyerror!*Engine {
    const engine = try conf.allocator.create(Engine);
    errdefer conf.allocator.destroy(engine);

    const address = try std.net.Address.parseIp(conf.addr, conf.port);
    var listener = try address.listen(.{ .reuse_address = true });
    errdefer listener.deinit();

    const route_tree = try RouteTree.init(.{
        .allocator = conf.allocator,
        .children = std.StringHashMap(*RouteTree).init(conf.allocator),
        .routes = std.ArrayList(*Route).init(conf.allocator),
    });
    errdefer route_tree.destroy();

    engine.* = Engine{
        .allocator = conf.allocator,
        .net_server = listener,

        .read_buffer_len = conf.read_buffer_len,
        .header_buffer_len = conf.header_buffer_len,
        .body_buffer_len = conf.body_buffer_len,

        .router = try Router.init(.{
            .allocator = conf.allocator,
            .middlewares = std.ArrayList(HandlerFn).init(conf.allocator),
        }),
        .catchers = try Catchers.init(conf.allocator),
        .middlewares = std.ArrayList(HandlerFn).init(conf.allocator),
        .threads = std.ArrayList(std.Thread).init(conf.allocator),

        .num_threads = conf.num_threads,
        .stack_size = conf.stack_size,
    };

    if (engine.num_threads > 0) {
        for (engine.num_threads) |_| {
            const thread = try std.Thread.spawn(.{
                .stack_size = engine.stack_size,
                .allocator = engine.allocator,
            }, Engine.worker, .{engine});

            // std.debug.print("\nCreate worker thread", .{});
            try engine.threads.append(thread);
        }
    }

    return engine;
}

/// Initialize the engine.
pub fn init(conf: Config.Engine) anyerror!*Engine {
    return try create(conf);
}

pub fn deinit(self: *Self) void {
    std.debug.print("\nEngine is stopping", .{});

    if (std.net.tcpConnectToAddress(self.net_server.listen_address)) |c| c.close() else |_| {}
    self.net_server.deinit();

    if (self.threads.items.len > 0) {
        for (self.threads.items, 0..) |*t, i| {
            _ = i;
            // std.debug.print("\nThread is closed. {d}", .{i});
            t.join();
        }
        std.debug.print("\nAll threads have been shut down. {d}", .{self.threads.items.len});
        self.threads.deinit();
        std.debug.print("\nThreads deinit", .{});
    }

    std.debug.print("\nMiddlewares deinit", .{});
    if (self.middlewares) |m| m.deinit();

    std.debug.print("\nCatchers deinit", .{});
    if (self.catchers) |c| c.deinit();

    std.debug.print("\nRouter deinit", .{});
    if (self.router) |r| r.deinit();

    std.debug.print("\nEngine is stopped", .{});
    if (!self.stopped.isSet()) self.stopped.set();

    std.debug.print("\nDestroy engine.", .{});
    self.allocator.destroy(self);

    std.debug.print("\n-------------- All Done. --------------\r\n", .{});
}

/// Accept a new connection.
fn accept(self: *Engine) ?std.net.Server.Connection {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.stopping.isSet()) return null;

    const conn = self.net_server.accept() catch |e| {
        if (self.stopping.isSet()) return null;

        switch (e) {
            error.ConnectionAborted => {
                // return self.accept();
                return null;
            },
            else => return {
                return null;
            },
        }
    };

    return conn;
}

/// Run the server. This function will block the current thread.
pub fn run(self: *Engine) !void {
    // defer self.deinit();
    self.wait();
}

/// Allocate server worker threads
fn worker(self: *Engine) anyerror!void {
    self.spawn_count += 1;
    // std.debug.print("\nworker is running. {d}", .{self.spawn_count});

    // var arena = std.heap.ArenaAllocator.init(self.allocator);
    // defer arena.deinit();
    // const engine_allocator = arena.allocator();

    const engine_allocator = self.allocator;

    var router = self.getRouter();
    const catchers = self.getCatchers();

    const read_buffer_len = self.read_buffer_len;
    var read_buffer: []u8 = undefined;
    read_buffer = try engine_allocator.alloc(u8, read_buffer_len);
    defer engine_allocator.free(read_buffer);

    // Engine is stopping.
    if (self.stopping.isSet()) return;

    accept: while (self.accept()) |conn| {
        if (self.stopping.isSet()) return;

        var http_server = http.Server.init(conn, read_buffer);

        ready: while (http_server.state == .ready) {
            // defer _ = arena.reset(.{ .retain_with_limit = read_buffer_len });

            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => continue :ready,
                error.HttpHeadersOversize => return default_response.requestHeaderFieldsTooLarge(conn.stream),
                else => {
                    try default_response.badRequest(conn.stream);
                    continue :accept;
                },
            };

            var req = Request.init(.{ .req = &request, .allocator = engine_allocator });
            var res = Response.init(.{ .req = &request, .allocator = engine_allocator });
            var ctx = try Context.init(.{ .request = &req, .response = &res, .server_request = &request, .allocator = engine_allocator });

            const match_route = router.getRoute(request.head.method, request.head.target) catch |err| {
                try catchRouteError(@constCast(catchers), err, conn.stream, ctx);
                continue :accept;
            };

            // TODO ??
            ctx.handlers = match_route.handlers;
            ctx.handle() catch try default_response.internalServerError(conn.stream);
        }

        // closing
        while (http_server.state == .closing) {
            continue :accept;
        }
    }
}

fn catchRouteError(self: *Catchers, err: anyerror, stream: net.Stream, ctx: *Context) anyerror!void {
    switch (err) {
        Route.RouteError.NotFound => {
            if (!ctx.request.method.responseHasBody()) {
                _ = try stream.write("HTTP/1.1 404 Not Found\r\n\r\n");
                return;
            }

            if (self.get(.not_found)) |notFoundHande| {
                try notFoundHande(ctx);
                return;
            }
            try default_response.notFound(stream);
            return;
        },
        Route.RouteError.MethodNotAllowed => {
            if (self.get(.method_not_allowed)) |methodNotAllowedHande| {
                try methodNotAllowedHande(ctx);
                return;
            }
            try default_response.methodNotAllowed(stream);
            return;
        },
        else => |e| return e,
    }
}

/// Create a new engine with default options.
/// The default options are:
/// - addr: "127.0.0.1" (default address)
/// - port: 0 (random port)
/// - allocator: arena.allocator (std.heap.ArenaAllocator with std.heap.GeneralPurposeAllocator)
/// - read_buffer_len: 10240 (10KB)
/// - header_buffer_len: 1024 (1KB)
/// - body_buffer_len: 8192 (8KB)
/// - stack_size: 10485760 (10MB)
/// - num_threads: 8 (8 threads)
pub fn default() anyerror!*Engine {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());

    defer {
        arena.deinit();
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.print("memory leak detected", .{});
        }
    }

    const allocator = arena.allocator();

    var engine = try init(.{
        .addr = "127.0.0.1",
        .port = 0,
    });
    engine.allocator = allocator;
    return engine;
}

pub fn getPort(self: *Self) u16 {
    return self.net_server.listen_address.getPort();
}

pub fn getAddress(self: *Self) net.Address {
    return self.net_server.listen_address;
}

/// Wait for the server to stop.
pub fn wait(self: *Self) void {
    self.stopped.wait();
}

/// Shutdown the server.
pub fn shutdown(self: *Self, timeout_ns: u64) void {
    std.time.sleep(timeout_ns);
    std.debug.print("\nEngine is shutting down", .{});
    if (!self.stopping.isSet()) self.stopping.set();

    if (!self.stopped.isSet()) {
        self.cond.broadcast();
        self.stopped.set();
    }
}

/// Add custom router to engine.s
pub fn addRouter(self: *Self, r: Router) void {
    self.router = r;
}

/// Get the router.
pub fn getRouter(self: *Self) *Router {
    return self.router.?;
}

/// Get the catchers.
pub fn getCatchers(self: *Self) *Catchers {
    return self.catchers.?;
}

/// Get the catcher by status.
fn getCatcher(self: *Self, status: http.Status) ?HandlerFn {
    return self.catchers.get(status);
}

/// use middleware to match any route
pub fn use(self: *Self, handlers: []const HandlerFn) anyerror!void {
    try self.middlewares.?.appendSlice(handlers);
    try self.router.?.use(handlers);
}

fn routeRebuild(self: *Self) anyerror!void {
    self.router.?.use(self.middlewares.items);
}

// Serve a static file.
pub fn StaticFile(self: *Self, path: []const u8, file_name: []const u8) anyerror!void {
    try self.router.?.staticFile(path, file_name);
}

/// Serve a static directory.
pub fn static(self: *Self, path: []const u8, dir_name: []const u8) anyerror!void {
    try self.router.?.static(path, dir_name);
}

/// Engine error.
pub const EngineError = error{
    None,
    Stopping,
    Stopped,
};
