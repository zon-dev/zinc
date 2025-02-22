const std = @import("std");

const http = std.http;
const posix = std.posix;
const mem = std.mem;
const net = std.net;
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

const IO = @import("io.zig");
const AIO = zinc.AIO.IO;

const server = @import("./server.zig");
// const Server = @import("./server.zig").Server;

const utils = @import("utils.zig");

pub const Engine = @This();
const Self = @This();

allocator: Allocator = undefined,
arena: std.heap.ArenaAllocator = undefined,

process: struct {
    // id: u8,
    accept_fd: posix.socket_t,
    accept_address: std.net.Address,
    accept_completion: AIO.Completion = undefined,
    accept_connection: ?*IO.Connection = null,
    clients: std.AutoHashMapUnmanaged(u128, *IO.Connection) = .{},
},

connections: []IO.Connection = undefined,
connections_used: usize = 0,

// threads
// threads: std.ArrayList(std.Thread) = undefined,
threads: std.Thread.Pool = undefined,
stopping: std.Thread.ResetEvent = .{},
stopped: std.Thread.ResetEvent = .{},
mutex: std.Thread.Mutex = .{},

/// see at https://github.com/ziglang/zig/blob/master/lib/std/Thread/Condition.zig
cond: Condition = .{},
num_threads: usize = 0,
spawn_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

connection_pool: std.heap.MemoryPool(IO.Connection) = undefined,

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

io: *IO.IO = undefined,

aio: AIO = undefined,

/// Create a new engine.
fn create(conf: Config.Engine) anyerror!*Engine {
    const allocator = conf.allocator;
    const engine = try allocator.create(Engine);
    errdefer allocator.destroy(engine);

    const address = try std.net.Address.parseIp(conf.addr, conf.port);
    var listener = try server.listen(address, .{
        .reuse_address = true,
        .force_nonblocking = conf.force_nonblocking,
    });

    errdefer listener.deinit();

    var io = try allocator.create(IO.IO);
    errdefer allocator.destroy(io);
    io.* = try IO.IO.init(32, 0);
    errdefer io.deinit();

    engine.* = Engine{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .io = io,

        .read_buffer_len = conf.read_buffer_len,
        .header_buffer_len = conf.header_buffer_len,
        .body_buffer_len = conf.body_buffer_len,

        .router = try Router.init(.{
            .allocator = allocator,
            .middlewares = std.ArrayList(HandlerFn).init(allocator),
            .data = conf.data,
        }),
        .middlewares = std.ArrayList(HandlerFn).init(allocator),

        .threads = undefined,

        .num_threads = conf.num_threads,
        .stack_size = conf.stack_size,

        .process = undefined,
        .connections = undefined,

        .connection_pool = std.heap.MemoryPool(IO.Connection).init(allocator),
    };

    try engine.threads.init(.{
        .allocator = allocator,
        .n_jobs = conf.num_threads,
        .track_ids = false,
    });

    engine.process = .{
        .accept_fd = listener.stream.handle,
        .accept_address = listener.listen_address,
        .accept_completion = undefined,
        .accept_connection = null,
    };

    return engine;
}

const ClientSocket = struct {
    fd: std.posix.socket_t,
    address: net.Address,
};

fn getClientSocket(self: *Engine) !ClientSocket {
    var client_address = std.net.Address.initIp4(undefined, undefined);
    var client_address_len = client_address.getOsSockLen();

    try posix.getsockname(self.getAcceptFD(), &client_address.any, &client_address_len);
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
    const allocator = self.allocator;

    if (!self.stopping.isSet()) self.stopping.set();

    // Broadcast to all threads to stop.
    self.cond.broadcast();

    if (std.net.tcpConnectToAddress(self.getAddress())) |c| c.close() else |_| {}
    if (self.getSocket() >= 0) posix.close(self.getSocket());

    self.threads.deinit();

    // self.aio.close_socket(self.getSocket());
    // self.aio.cancelAll();
    // self.aio.deinit();
    self.io.deinit();
    allocator.destroy(self.io);

    if (self.middlewares) |m| m.deinit();

    self.router.deinit();

    if (!self.stopped.isSet()) self.stopped.set();

    self.arena.deinit();

    allocator.destroy(self);
}

/// Accept a new connection.
fn accept(self: *Engine) ?std.net.Stream {
    if (self.stopping.isSet()) return null;

    // TODO Too slow.
    const conn = self.blockAccept() catch |e| {
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
fn blockAccept(self: *Engine) !std.net.Stream {
    var accepted_addr: std.net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
    const fd = try posix.accept(self.getSocket(), &accepted_addr.any, &addr_len, posix.SOCK.CLOEXEC);
    return .{ .handle = fd };
}

fn nonblockAccept(self: *Engine) !std.net.Stream {
    var accepted_addr: std.net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
    const fd = try posix.accept(self.getSocket(), &accepted_addr.any, &addr_len, posix.SOCK.NONBLOCK);
    return .{ .handle = fd };
}

/// Run the server. This function will block the current thread.
pub fn run(self: *Engine) !void {
    std.debug.print("running!\r\n", .{});
    try self.worker();
}

const res_buffer = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nHello World";

/// Allocate server worker threads
fn worker(self: *Engine) anyerror!void {
    // std.debug.print("std.math.maxInt(usize) {d}\r\n", .{std.math.maxInt(c_int)});
    const workder_id = self.spawn_count.fetchAdd(1, .monotonic);
    std.debug.print("{d} | worker start!\r\n", .{workder_id});

    const listener = self.getSocket();

    try self.io.monitorAccept(listener);

    while (!self.stopping.isSet()) {
        var it = try self.io.wait(null);
        while (it.next()) |event| {
            // TODO create a new thread to process the request

            switch (event) {
                .accept => {
                    try self.processAccept(listener);
                },
                .recv => |connection| {
                    switch (connection.state) {
                        .accepting => {
                            try self.processAccepting(connection, connection.getSocket(), listener);
                            connection.state = .connected;
                        },
                        .connected => {

                            //TODO Improve the performance of the following code
                            const buffer = self.processConnected(connection) catch |err| {
                                switch (err) {
                                    error.ConnectionResetByPeer => {
                                        connection.state = .terminating;
                                        posix.close(connection.getSocket());
                                        continue;
                                    },
                                    else => {
                                        posix.close(connection.getSocket());
                                        continue;
                                    },
                                }
                            };
                            if (buffer.len == 0) {
                                connection.state = .terminating;
                                posix.close(connection.getSocket());
                                continue;
                            }
                            self.router.handleConn(self.allocator, connection.getSocket(), buffer) catch |err| {
                                try catchRouteError(err, connection.getSocket());
                                posix.close(connection.getSocket());
                                continue;
                            };

                            self.io.signal() catch |err| std.log.err("failed to signal worker: {}", .{err});
                        },
                        .terminating => {
                            posix.close(connection.getSocket());
                            self.io.signal() catch |err| std.log.err("failed to signal worker: {}", .{err});
                        },
                        else => {
                            std.debug.print("got a unknown connection state:{any}\n", .{connection.state});
                        },
                    }
                },
                .signal => {
                    self.processSignal();
                },
                else => {
                    std.debug.print("got a unknown ready_socket:{any}\n", .{event});
                },
            }
        }
    }
}

fn processAccept(self: *Engine, listener: std.posix.socket_t) !void {
    _ = listener;

    const conn = self.nonblockAccept() catch |err| {
        switch (err) {
            error.WouldBlock => {
                return;
            },
            else => return err,
        }
    };
    const client_socket = conn.handle;
    errdefer posix.close(client_socket);

    const connection = try self.connection_pool.create();
    errdefer self.allocator.destroy(connection);
    connection.* = IO.Connection.init(.{
        .state = .accepting,
        .fd = client_socket,
    });

    try self.io.monitorRead(connection);
}

fn processConnected(self: *Engine, connection: *IO.Connection) ![]u8 {
    const socket_fd = connection.getSocket();
    if (socket_fd < 0) return &[_]u8{};

    const bytes = try self.allocator.alloc(u8, 4096);
    const read = try std.posix.read(socket_fd, bytes);
    return bytes[0..read];
}

fn processSignal(self: *Engine) void {
    _ = self;
}

fn processAccepting(self: *Engine, conn: *IO.Connection, client: std.posix.socket_t, listener: std.posix.socket_t) !void {
    std.debug.assert(conn.state == .accepting);

    _ = self;
    _ = listener;
    _ = client;
}

pub fn requestDone(self: *Engine, retain_size: usize) void {
    _ = self.arena.reset(.{ .retain_with_limit = retain_size });
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

pub fn getSocket(self: *Self) posix.socket_t {
    return self.process.accept_fd;
}

pub fn getAcceptAddress(self: *Self) std.net.Address {
    return self.process.accept_address;
}

pub fn getPort(self: *Self) u16 {
    return self.getAddress().getPort();
}

pub fn getAddress(self: *Self) net.Address {
    return self.process.accept_address;
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
