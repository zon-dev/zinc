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

const utils = @import("utils.zig");

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
middlewares: ?std.ArrayList(HandlerFn) = undefined,

/// Create a new engine.
fn create(conf: Config.Engine) anyerror!*Engine {
    const engine = try conf.allocator.create(Engine);
    errdefer conf.allocator.destroy(engine);

    const address = try std.net.Address.parseIp(conf.addr, conf.port);
    var listener = try address.listen(.{ .reuse_address = true });
    errdefer listener.deinit();

    const route_tree = try RouteTree.init(.{
        .value = "/",
        .full_path = "/",
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
        .middlewares = std.ArrayList(HandlerFn).init(conf.allocator),
        .threads = std.ArrayList(std.Thread).init(conf.allocator),

        .num_threads = conf.num_threads,
        .stack_size = conf.stack_size,
    };

    var num_threads = engine.num_threads;
    if (num_threads > 1) {
        // The main thread is also a worker.
        // So we need to subtract 1 from the number of threads.
        num_threads -= 1;

        for (num_threads) |_| {
            const thread = try std.Thread.spawn(.{
                .stack_size = engine.stack_size,
                .allocator = engine.allocator,
            }, Engine.worker, .{engine});

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
    if (!self.stopping.isSet()) self.stopping.set();

    // Broadcast to all threads to stop.
    self.cond.broadcast();

    if (std.net.tcpConnectToAddress(self.net_server.listen_address)) |c| c.close() else |_| {}
    self.net_server.deinit();

    if (self.threads.items.len > 0) {
        for (self.threads.items, 0..) |*t, i| {
            _ = i;
            t.join();
        }
        self.threads.deinit();
    }

    if (self.middlewares) |m| m.deinit();

    if (self.router) |r| r.deinit();

    if (!self.stopped.isSet()) self.stopped.set();

    self.allocator.destroy(self);
}

/// Accept a new connection.
fn accept(self: *Engine) ?std.net.Server.Connection {
    // self.mutex.lock();
    // defer self.mutex.unlock();

    if (self.stopping.isSet()) return null;

    const conn = self.net_server.accept() catch |e| {
        if (self.stopping.isSet()) return null;
        switch (e) {
            error.ConnectionAborted => {
                return null;
            },
            else => return null,
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

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const read_buffer_len = self.read_buffer_len;
    var read_buffer: []u8 = undefined;

    var router = self.getRouter();

    accept: while (self.accept()) |conn| {
        read_buffer = try arena_allocator.alloc(u8, read_buffer_len);
        defer arena_allocator.free(read_buffer);

        var http_server = http.Server.init(conn, read_buffer);

        ready: while (http_server.state == .ready) {
            // TODO Too slow, need to optimize.
            // defer _ = arena.reset(.{ .retain_with_limit = self.read_buffer_len });
            // defer _ = arena.reset(.retain_capacity);

            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpHeadersUnreadable => continue :accept,
                error.HttpConnectionClosing => continue :ready,
                error.HttpHeadersOversize => return utils.response(.request_header_fields_too_large, conn.stream),
                else => {
                    try utils.response(.bad_request, conn.stream);
                    continue :accept;
                },
            };

            // TODO Catchers handle error.
            router.handleRequest(arena_allocator, &request) catch |err| {
                catchRouteError(err, conn.stream) catch continue :accept;
            };
        }

        // closing
        while (http_server.state == .closing) {
            continue :accept;
        }
    }
}

fn catchRouteError(err: anyerror, stream: net.Stream) anyerror!void {
    switch (err) {
        Route.RouteError.NotFound => {
            return try utils.response(.not_found, stream);
        },
        Route.RouteError.MethodNotAllowed => {
            return try utils.response(.method_not_allowed, stream);
        },
        else => {
            try utils.response(.internal_server_error, stream);
            return err;
        },
    }
}

/// Create a new engine with default options.
/// The default options are:
/// - addr: "127.0.0.1" (default address)
/// - port: 0 (random port)
/// - allocator: std.heap.GeneralPurposeAllocator{}.allocator
/// - read_buffer_len: 10240 (10KB)
/// - header_buffer_len: 1024 (1KB)
/// - body_buffer_len: 8192 (8KB)
/// - stack_size: 10485760 (10MB)
/// - num_threads: 8 (8 threads)
pub fn default() anyerror!*Engine {
    return try init(.{});
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

    if (!self.stopping.isSet()) self.stopping.set();

    if (!self.stopped.isSet()) {
        self.cond.broadcast();
        self.stopped.set();
    }
}

// /// Add custom router to engine.s
// pub fn addRouter(self: *Self, r: Router) void {
//     self.router = r;
// }

/// Get the router.
pub fn getRouter(self: *Self) *Router {
    return self.router.?;
}

/// Get the catchers.
pub fn getCatchers(self: *Self) *Catchers {
    return self.router.?.catchers.?;
}

/// use middleware to match any route
pub fn use(self: *Self, handlers: []const HandlerFn) anyerror!void {
    try self.middlewares.?.appendSlice(handlers);
    try self.router.?.use(self.middlewares.?.items);
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
