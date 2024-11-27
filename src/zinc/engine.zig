const std = @import("std");
const builtin = @import("builtin");

const http = std.http;
const posix = std.posix;
const mem = std.mem;
const net = std.net;
// const assert = std.testing.assert;
// const Server = std.http.Server;
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

const IO = @import("./io.zig").IO;

const Signal = @import("./signal.zig").Signal;
const server = @import("./server.zig");
const Server = @import("./server.zig").Server;

const utils = @import("utils.zig");

pub const Engine = @This();
const Self = @This();

allocator: Allocator = undefined,

/// The IO engine.
io: *IO,

server_socket: std.posix.socket_t,
client_socket: std.posix.socket_t,

connect_socket: std.posix.socket_t,

/// The file descriptor for the process on which to accept connections.
accept_fd: posix.socket_t = undefined,
/// Address the accept_fd is bound to, as reported by `getsockname`.
///
/// This allows passing port 0 as an address for the OS to pick an open port for us
/// in a TOCTOU immune way and logging the resulting port number.
accept_address: std.net.Address,

// accept_completion: IO.Completion = undefined,

/// The completion for the server.
completion: IO.Completion,

/// Signal for the engine.
signal: Signal,

// threads
threads: std.ArrayList(std.Thread) = undefined,
stopping: std.Thread.ResetEvent = .{},
stopped: std.Thread.ResetEvent = .{},
mutex: std.Thread.Mutex = .{},

/// see at https://github.com/ziglang/zig/blob/master/lib/std/Thread/Condition.zig
cond: Condition = .{},
completed: Condition = .{},
num_threads: usize = 0,
spawn_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

/// Thread stack size.
stack_size: usize = undefined,

// buffer len for every connection,
// The total memory usage for each connection is:
// read_buffer_len * thread_num
read_buffer_len: usize = undefined,

/// header buffer len for every connection
header_buffer_len: usize = undefined,
/// body buffer len for every connection
body_buffer_len: usize = undefined,

///
router: *Router = undefined,

///
middlewares: ?std.ArrayList(HandlerFn) = undefined,

/// max connections.
max_conn: u32 = 1024,

/// Create a new engine.
fn create(conf: Config.Engine) anyerror!*Engine {
    const engine = try conf.allocator.create(Engine);
    errdefer conf.allocator.destroy(engine);

    const address = try std.net.Address.parseIp(conf.addr, conf.port);
    var listener = try server.listen(address, .{
        .reuse_address = true,
        .force_nonblocking = conf.force_nonblocking,
    });

    errdefer listener.deinit();

    const route_tree = try RouteTree.init(.{
        .value = "/",
        .full_path = "/",
        .allocator = conf.allocator,
        .children = std.StringHashMap(*RouteTree).init(conf.allocator),
        .routes = std.ArrayList(*Route).init(conf.allocator),
    });
    errdefer route_tree.destroy();

    var io = try conf.allocator.create(IO);
    errdefer conf.allocator.destroy(io);
    io.* = try IO.init(32, 0);
    errdefer io.deinit();

    engine.* = Engine{
        .allocator = conf.allocator,

        .server_socket = IO.INVALID_SOCKET,
        .client_socket = IO.INVALID_SOCKET,

        .connect_socket = IO.INVALID_SOCKET,
        .accept_fd = IO.INVALID_SOCKET,

        .accept_address = undefined,

        .io = io,
        .signal = undefined,

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

        .completion = undefined,
    };

    engine.server_socket = listener.stream.handle;

    engine.accept_fd = listener.stream.handle;
    engine.accept_address = listener.listen_address;

    // engine.connect_socket = try IO.connectSocket(engine.serverSocket(), engine.io);

    // try engine.signal.init(engine.serverAddress(), engine.serverSocket(), io, on_signal_fn);
    // errdefer engine.signal.deinit();

    return engine;
}

const ClientSocket = struct {
    fd: std.posix.socket_t,
    address: net.Address,
};

fn get_client_socket(self: *Engine) !ClientSocket {
    var client_address = std.net.Address.initIp4(undefined, undefined);
    var client_address_len = client_address.getOsSockLen();

    try posix.getsockname(self.server_socket, &client_address.any, &client_address_len);
    const client: std.posix.socket_t = try self.io.open_socket(
        client_address.any.family,
        posix.SOCK.STREAM,
        posix.IPPROTO.TCP,
    );
    return .{ .fd = client, .address = client_address };
}

/// Initialize the engine.
pub fn init(conf: Config.Engine) anyerror!*Engine {
    return try create(conf);
}

pub fn deinit(self: *Self) void {
    if (!self.stopping.isSet()) self.stopping.set();

    // Broadcast to all threads to stop.
    self.cond.broadcast();

    if (std.net.tcpConnectToAddress(self.accept_address)) |c| c.close() else |_| {}
    std.posix.close(self.accept_fd);

    self.signal.notify();

    if (self.threads.items.len > 0) {
        for (self.threads.items, 0..) |*t, i| {
            _ = i;
            t.join();
        }
        self.threads.deinit();
    }

    self.io.close_socket(self.accept_fd);
    self.io.close_socket(self.connect_socket);

    self.io.cancel_all();
    self.io.deinit();
    self.signal.deinit();

    if (self.middlewares) |m| m.deinit();

    self.router.deinit();

    if (!self.stopped.isSet()) self.stopped.set();

    self.allocator.destroy(self);
}

/// Accept a new connection.
fn accept(self: *Engine) ?std.net.Stream {
    if (self.stopping.isSet()) return null;

    // TODO Too slow.
    const conn = self.block_accept() catch |e| {
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

/// See std.net.Server.accept()
fn block_accept(self: *Engine) !std.net.Stream {
    var accepted_addr: std.net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
    const fd = try posix.accept(self.server_socket, &accepted_addr.any, &addr_len, posix.SOCK.CLOEXEC);
    return .{ .handle = fd };
}

/// Run the server. This function will block the current thread.
pub fn run(self: *Engine) !void {
    std.debug.print("running!\r\n", .{});
    for (0..self.num_threads) |_| {
        const thread = try std.Thread.spawn(.{
            .stack_size = self.stack_size,
            .allocator = self.allocator,
        }, Engine.worker, .{self});
        errdefer thread.detach();

        try self.threads.append(thread);
    }

    for (self.threads.items) |thrd| {
        thrd.join();
    }

    while (!self.stopping.isSet()) {
        self.io.tick() catch |err| {
            std.debug.print("IO.tick() failed: {any}", .{err});
            continue;
        };

        self.io.run_for_ns(10 * std.time.ns_per_ms) catch |err| {
            std.debug.print("IO.run() failed: {any}", .{err});
            continue;
        };
    }

    std.debug.print("run end!\r\n", .{});
}

const res_buffer = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nHello World";

/// Allocate server worker threads
fn worker(self: *Engine) anyerror!void {
    const workder_id = self.spawn_count.fetchAdd(1, .monotonic);
    std.debug.print("{d} | worker start!\r\n", .{workder_id});

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const read_buffer_len = self.read_buffer_len;
    var read_buffer: []u8 = undefined;
    read_buffer = try arena_allocator.alloc(u8, read_buffer_len);
    defer arena_allocator.free(read_buffer);

    // var router = self.getRouter();

    while (self.accept()) |conn| {
        if (self.stopping.isSet()) break;

        std.debug.print("worker {d} | accept\r\n", .{workder_id});
        defer conn.close();

        self.io.send(*Self, self, send_callback, &self.completion, conn.handle, res_buffer);

        // try self.io.tick();
    }

    // while (!self.stopping.isSet()) {
    //     std.debug.print("worker {d} | IO.run_for_ns(10 * std.time.ns_per_ms)\r\n", .{workder_id});
    // }
}

fn send_callback(self: *Self, completion: *IO.Completion, result: IO.SendError!usize) void {
    _ = self;
    _ = completion;
    _ = result catch |err| {
        std.debug.print("send_callback error: {any}\n", .{err});
    };
}

fn server_accept(
    self: *Engine,
    completion: *IO.Completion,
    result: IO.AcceptError!std.posix.socket_t,
) void {
    std.debug.assert(self.accept_fd == IO.INVALID_SOCKET);
    self.accept_fd = result catch |err| {
        std.debug.print("accept error: {}", .{err});
        return;
    };
    _ = completion;
}

fn catchRouteError(err: anyerror, stream: std.posix.socket_t) anyerror!void {
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
    return self.accept_address.getPort();
}

pub fn getAddress(self: *Self) net.Address {
    return self.accept_address;
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

/// Get the router.
pub fn getRouter(self: *Self) *Router {
    return self.router;
}

/// Get the catchers.
pub fn getCatchers(self: *Self) *Catchers {
    return self.router.catchers.?;
}

/// use middleware to match any route
pub fn use(self: *Self, handlers: []const HandlerFn) anyerror!void {
    try self.middlewares.?.appendSlice(handlers);
    try self.router.use(self.middlewares.?.items);
}

// Serve a static file.
pub fn StaticFile(self: *Self, path: []const u8, file_name: []const u8) anyerror!void {
    try self.router.staticFile(path, file_name);
}

/// Serve a static directory.
pub fn static(self: *Self, path: []const u8, dir_name: []const u8) anyerror!void {
    try self.router.static(path, dir_name);
}

/// Engine error.
pub const EngineError = error{
    None,
    Stopping,
    Stopped,
};
