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

const IO = zinc.IO.IO;

const server = @import("./server.zig");
// const Server = @import("./server.zig").Server;

const utils = @import("utils.zig");

pub const Engine = @This();
const Self = @This();

allocator: Allocator = undefined,
arena: std.heap.ArenaAllocator = undefined,

/// The IO engine.
io: *IO,

// accept_fd: posix.socket_t = undefined,
// accept_address: std.net.Address = undefined,

process: struct {
    // id: u8,
    accept_fd: posix.socket_t,
    accept_address: std.net.Address,
    accept_completion: IO.Completion = undefined,
    accept_connection: ?*Connection = null,
    clients: std.AutoHashMapUnmanaged(u128, *Connection) = .{},
},

connections: []Connection = undefined,
connections_used: usize = 0,

// threads
threads: std.ArrayList(std.Thread) = undefined,
stopping: std.Thread.ResetEvent = .{},
stopped: std.Thread.ResetEvent = .{},
mutex: std.Thread.Mutex = .{},

/// see at https://github.com/ziglang/zig/blob/master/lib/std/Thread/Condition.zig
cond: Condition = .{},
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

/// Used to send/receive messages to/from a client or fellow replica.
const Connection = struct {
    const Peer = union(enum) {
        /// No peer is currently connected.
        none: void,
        /// A connection is established but an unambiguous header has not yet been received.
        unknown: void,
        /// The peer is a client with the given id.
        client: u128,
        /// The peer is a replica with the given id.
        replica: u8,
    };

    /// The peer is determined by inspecting the first message header
    /// received.
    peer: Peer = .none,
    state: enum {
        /// The connection is not in use, with peer set to `.none`.
        free,
        /// The connection has been reserved for an in progress accept operation,
        /// with peer set to `.none`.
        accepting,
        /// The peer is a replica and a connect operation has been started
        /// but not yet completed.
        connecting,
        /// The peer is fully connected and may be a client, replica, or unknown.
        connected,
        /// The connection is being terminated but cleanup has not yet finished.
        terminating,
    } = .free,
    /// This is guaranteed to be valid only while state is connected.
    /// It will be reset to IO.INVALID_SOCKET during the shutdown process and is always
    /// IO.INVALID_SOCKET if the connection is unused (i.e. peer == .none). We use
    /// IO.INVALID_SOCKET instead of undefined here for safety to ensure an error if the
    /// invalid value is ever used, instead of potentially performing an action on an
    /// active fd.
    fd: posix.socket_t = IO.INVALID_SOCKET,

    /// This completion is used for all recv operations.
    /// It is also used for the initial connect when establishing a replica connection.
    recv_completion: IO.Completion = undefined,
    /// True exactly when the recv_completion has been submitted to the IO abstraction
    /// but the callback has not yet been run.
    recv_submitted: bool = false,
    /// The Message with the buffer passed to the kernel for recv operations.
    /// CommandMessageType
    // recv_message: ?*Message = null,
    /// The number of bytes in `recv_message` that have been received and need parsing.
    recv_progress: usize = 0,
    /// The number of bytes in `recv_message` that have been parsed.
    recv_parsed: usize = 0,
    /// True if we have already checked the header checksum of the message we
    /// are currently receiving/parsing.
    recv_checked_header: bool = false,

    /// This completion is used for all send operations.
    send_completion: IO.Completion = undefined,
    /// True exactly when the send_completion has been submitted to the IO abstraction
    /// but the callback has not yet been run.
    send_submitted: bool = false,
    /// Number of bytes of the current message that have already been sent.
    send_progress: usize = 0,
    // /// The queue of messages to send to the client or replica peer.
    // send_queue: SendQueue = SendQueue.init(),
};

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
        .arena = std.heap.ArenaAllocator.init(conf.allocator),
        .io = io,

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

        .process = undefined,
        .connections = undefined,
    };

    // engine.accept_fd = listener.stream.handle;
    // engine.accept_address = listener.listen_address;

    engine.process = .{
        // .id = 0,
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

fn get_client_socket(self: *Engine) !ClientSocket {
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
    if (!self.stopping.isSet()) self.stopping.set();

    // Broadcast to all threads to stop.
    self.cond.broadcast();

    if (std.net.tcpConnectToAddress(self.getAddress())) |c| c.close() else |_| {}
    std.posix.close(self.getSocket());

    if (self.threads.items.len > 0) {
        for (self.threads.items, 0..) |*t, i| {
            _ = i;
            t.join();
        }
        self.threads.deinit();
    }

    // self.io.close_socket(self.getSocket());

    self.io.cancel_all();
    self.io.deinit();

    if (self.middlewares) |m| m.deinit();

    self.router.deinit();

    if (!self.stopped.isSet()) self.stopped.set();

    self.arena.deinit();
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
    const fd = try posix.accept(self.getSocket(), &accepted_addr.any, &addr_len, posix.SOCK.CLOEXEC);
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

    // for (self.threads.items) |thrd| {
    //     thrd.join();
    // }

    while (!self.stopping.isSet()) {
        // std.debug.print("run start!\r\n", .{});
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

    const arena_allocator = self.arena.allocator();
    var read_buffer:[]u8 = try arena_allocator.alloc(u8, self.read_buffer_len);

    while (self.accept()) |conn| {
        defer arena_allocator.free(read_buffer);

        if (self.stopping.isSet()) break;

        std.debug.print("worker {d} | accept\r\n", .{workder_id});
        // defer conn.close();

        const read_size = try conn.read(read_buffer);
        // _ = read_buffer[0..read_size];

        self.router.handleConn(arena_allocator, self.io, conn.handle, read_buffer[0..read_size]) catch |err| {
            catchRouteError(err, conn.handle) catch {};
        };

        // var process_context: ProcessContext = try ProcessContext.init(.{
        //     .allocator = arena_allocator,
        //     .io = self.io,
        //     .server = self.getSocket(),
        //     .client = conn.handle,
        //     .router = self.getRouter(),
        //     .read_buffer = read_buffer,
        // });
        // var server_completion: IO.Completion = undefined;
        // self.io.recv(*ProcessContext, &process_context, recv_callback, &server_completion, process_context.client, process_context.read_buffer);
    }
}

const ProcessContext = struct {
    allocator: Allocator = undefined,
    io: *IO,
    done: bool = false,
    server: posix.socket_t,
    client: posix.socket_t,

    accepted_sock: posix.socket_t = undefined,

    // send_buf: []u8 = undefined,
    // recv_buf: []u8 = undefined,

    read_buffer: []u8 = undefined,

    sent: usize = 0,
    received: usize = 0,

    written: usize = 0,
    read: usize = 0,

    router: *Router,

    pub fn init(self: ProcessContext) !ProcessContext {
        return ProcessContext{
            .allocator = self.allocator,
            .io = self.io,
            .server = self.server,
            .client = self.client,
            .router = self.router,
        };
    }
};

fn accept_callback(self: *ProcessContext, completion: *IO.Completion, result: IO.AcceptError!posix.socket_t) void {
    self.accepted_sock = result catch @panic("accept error");
    self.io.recv(*ProcessContext, self, recv_callback, completion, self.accepted_sock, self.read_buffer);
}

fn recv_callback(self: *ProcessContext, completion: *IO.Completion, result: IO.RecvError!usize) void {
    _ = completion;
    self.received = result catch @panic("recv error");
    self.done = true;
    self.router.handleConn(self.allocator, self.io, self.client, self.read_buffer) catch |err| {
        // std.debug.print("recv_callback error: {any}\n", .{err});
        catchRouteError(err, self.client) catch {};
    };
}

fn send_callback(self: *Self, completion: *IO.Completion, result: IO.SendError!usize) void {
    _ = self;
    _ = completion;
    _ = result catch |err| {
        std.debug.print("send_callback error: {any}\n", .{err});
    };
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
