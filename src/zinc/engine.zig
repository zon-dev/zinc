const std = @import("std");

const http = std.http;
const posix = std.posix;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Condition = std.Thread.Condition;
const Io = std.Io;

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

// Import aio library directly
const aio = @import("aio");
const IO = aio.IO;
const Time = aio.Time;

const server = @import("./server.zig");

const utils = @import("utils.zig");

pub const Engine = @This();
const Self = @This();

allocator: Allocator = undefined,
arena: std.heap.ArenaAllocator = undefined,

// Aio engine for async I/O
aio_io: IO = undefined,
aio_time: Time = undefined,

// Server state
listener_socket: posix.socket_t = -1,
listener_address: std.Io.net.IpAddress = undefined,

// Connection management
connections: std.AutoHashMapUnmanaged(posix.socket_t, *Connection) = .{},

// Thread management
threads: std.Thread.Pool = undefined,
stopping: std.Thread.ResetEvent = .unset,
stopped: std.Thread.ResetEvent = .unset,
mutex: std.Thread.Mutex = .{},

/// see at https://github.com/ziglang/zig/blob/master/lib/std/Thread/Condition.zig
cond: Condition = .{},
num_threads: usize = 0,
spawn_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

connection_pool: std.heap.MemoryPool(Connection) = undefined,

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
middlewares: ?std.array_list.Managed(HandlerFn) = undefined,

/// max connections.
max_conn: u32 = 1024,

// Aio completion for accept operations (global, not per-connection)
accept_completion: IO.Completion = undefined,

// Read buffer for each connection
read_buffer: []u8 = undefined,

/// Connection wrapper for aio integration
pub const Connection = struct {
    state: enum {
        free,
        accepting,
        connecting,
        connected,
        read,
        write,
        terminating,
    } = .free,

    fd: posix.socket_t = -1,
    address: std.Io.net.IpAddress = undefined,

    // Each connection has its own completion objects to avoid race conditions
    read_completion: IO.Completion = undefined,
    write_completion: IO.Completion = undefined,

    // Store write buffer for cleanup after async write completes
    write_buffer: ?[]u8 = null,

    pub fn init() Connection {
        return .{};
    }

    pub fn getSocket(self: Connection) posix.socket_t {
        return self.fd;
    }

    pub fn setSocket(self: *Connection, fd: posix.socket_t) void {
        self.fd = fd;
    }

    pub fn setAddress(self: *Connection, addr: std.Io.net.IpAddress) void {
        self.address = addr;
    }
};

/// Create a new engine.
fn create(conf: Config.Engine) anyerror!*Engine {
    const allocator = conf.allocator;
    const engine = try allocator.create(Engine);
    errdefer allocator.destroy(engine);

    const address = try std.Io.net.IpAddress.parse(conf.addr, conf.port);
    var listener = try server.listen(address, .{
        .reuse_address = true,
    });

    errdefer listener.deinit();

    // Initialize aio with larger queue for better performance
    const aio_io = try IO.init(1024, 0);
    const aio_time = Time{};

    engine.* = Engine{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .aio_io = aio_io,
        .aio_time = aio_time,

        .read_buffer_len = conf.read_buffer_len,
        .header_buffer_len = conf.header_buffer_len,
        .body_buffer_len = conf.body_buffer_len,

        .router = try Router.init(.{
            .allocator = allocator,
            .middlewares = std.array_list.Managed(HandlerFn).init(allocator),
            .data = conf.data,
        }),
        .middlewares = std.array_list.Managed(HandlerFn).init(allocator),

        .threads = undefined,

        .num_threads = conf.num_threads,
        .stack_size = conf.stack_size,

        .listener_socket = listener.socket_fd,
        .listener_address = listener.listen_address,

        .connection_pool = std.heap.MemoryPool(Connection).empty,
        .read_buffer = try allocator.alloc(u8, 32768), // Increased to 32KB for maximum performance
    };

    try engine.threads.init(.{
        .allocator = allocator,
        .n_jobs = conf.num_threads,
        .track_ids = false,
        .stack_size = conf.stack_size,
    });

    return engine;
}

/// Initialize the engine.
pub fn init(conf: Config.Engine) anyerror!*Engine {
    return try create(conf);
}

pub fn deinit(self: *Self) void {
    const allocator = self.allocator;

    // Signal stopping
    if (!self.stopping.isSet()) self.stopping.set();

    // Broadcast to all threads to stop.
    self.cond.broadcast();

    // Close test connection if any (not needed with new API)

    // Close listener socket
    if (self.getSocket() >= 0) {
        posix.close(self.getSocket());
        self.listener_socket = -1;
    }

    // Wait for threads to finish
    self.threads.deinit();

    // Close all active connections
    var it = self.connections.iterator();
    while (it.next()) |entry| {
        const connection = entry.value_ptr.*;
        if (connection.fd != -1) {
            posix.close(connection.fd);
            connection.fd = -1;
        }

        // Destroy connection with mutex protection
        self.mutex.lock();
        self.connection_pool.destroy(@alignCast(connection));
        self.mutex.unlock();
    }
    self.connections.deinit(allocator);

    // Deinit aio
    self.aio_io.deinit();

    // Deinit middlewares
    if (self.middlewares) |*m| m.deinit();

    // Deinit router
    self.router.deinit();

    // Signal stopped
    if (!self.stopped.isSet()) self.stopped.set();

    // Deinit arena
    self.arena.deinit();

    // Free read buffer
    self.allocator.free(self.read_buffer);

    // Destroy engine
    allocator.destroy(self);
}

/// Run the server. This function will block the current thread.
pub fn run(self: *Engine) !void {
    // Removed debug print to avoid interfering with test runner
    try self.worker();
}

const res_buffer = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nHello World";

/// Allocate server worker threads
fn worker(self: *Engine) anyerror!void {
    const workder_id = self.spawn_count.fetchAdd(1, .monotonic);
    _ = workder_id; // Removed debug print to avoid interfering with test runner

    const listener = self.getSocket();

    // Start accepting connections using aio
    try self.startAccept(listener);

    while (!self.stopping.isSet()) {
        // Run aio event loop with error handling
        // Check stopping flag before and after run to ensure we exit quickly
        if (self.stopping.isSet()) break;
        self.aio_io.run() catch |err| {
            // Only log errors if we're not stopping
            if (!self.stopping.isSet()) {
                std.log.err("AIO run error: {}", .{err});
            }
            break;
        };
        // Check again after run in case stopping was set during run
        if (self.stopping.isSet()) break;
    }

    // Removed debug print to avoid interfering with test runner
}

/// Start accepting connections
fn startAccept(self: *Engine, socket: posix.socket_t) !void {
    self.aio_io.accept(
        *Engine,
        self,
        acceptCallback,
        &self.accept_completion,
        socket,
    );
}

/// Start reading from a connection
fn startRead(self: *Engine, connection: *Connection) !void {
    self.aio_io.recv(
        *Engine,
        self,
        readCallback,
        &connection.read_completion,
        connection.fd,
        self.read_buffer,
    );
}

/// Start writing to a connection
/// Note: data must be allocated and will be freed in writeCallback
pub fn startWrite(self: *Engine, connection: *Connection, data: []const u8) !void {
    // Store the data buffer for cleanup in writeCallback
    // Cast const to mutable for storage (we own this memory)
    connection.write_buffer = @constCast(data);

    self.aio_io.send(
        *Engine,
        self,
        writeCallback,
        &connection.write_completion,
        connection.fd,
        data,
    );
}

/// Handle accepted connection
fn handleAcceptedConnection(self: *Engine, client_fd: posix.socket_t) void {
    // Create new connection with minimal mutex protection
    const connection = blk: {
        self.mutex.lock();
        defer self.mutex.unlock();
        break :blk self.connection_pool.create(self.allocator) catch |err| {
            std.log.err("Failed to create connection: {}", .{err});
            posix.close(client_fd);
            return;
        };
    };
    connection.setSocket(client_fd);
    connection.state = .connected;

    // Add to managed connections (this doesn't need mutex protection)
    self.connections.put(self.allocator, client_fd, connection) catch |err| {
        std.log.err("Failed to add connection: {}", .{err});

        // Destroy connection with mutex protection
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connection_pool.destroy(@alignCast(connection));

        posix.close(client_fd);
        return;
    };

    // Start reading from the connection
    self.startRead(connection) catch |err| {
        std.log.err("Failed to start reading: {}", .{err});
        self.closeConnection(connection);
    };
}

/// Handle read completion
fn handleReadCompletion(self: *Engine, connection: *Connection, data: []u8) void {
    if (data.len == 0) {
        // Connection closed by client
        self.closeConnection(connection);
        return;
    }

    // Process the HTTP request with engine and connection for async operations
    // The response will be sent asynchronously, and writeCallback will handle
    // continuing to read for keep-alive connections
    self.router.handleConn(self.allocator, connection.getSocket(), data, self, connection) catch |err| {
        catchRouteError(err, connection.getSocket()) catch |err2| {
            std.log.err("Failed to handle route error: {}", .{err2});
        };
        // 错误处理后关闭连接
        self.closeConnection(connection);
        return;
    };

    // Note: We don't start reading here because the response is sent asynchronously.
    // The writeCallback will handle continuing to read after the write completes.
    // This ensures proper ordering: read -> process -> write -> read (for keep-alive)
}

/// Handle write completion
fn handleWriteCompletion(self: *Engine, connection: *Connection, bytes_written: usize) void {
    _ = bytes_written;

    // Free the write buffer that was allocated in sendAsync
    if (connection.write_buffer) |buffer| {
        self.allocator.free(buffer);
        connection.write_buffer = null;
    }

    // Continue reading after write for keep-alive connections
    self.startRead(connection) catch |err| {
        std.log.err("Failed to continue reading after write: {}", .{err});
        self.closeConnection(connection);
    };
}

/// Close a connection
fn closeConnection(self: *Engine, connection: *Connection) void {
    if (connection.fd != -1) {
        self.aio_io.close_socket(connection.fd);
        _ = self.connections.remove(connection.fd);

        // Only protect the actual destroy operation
        self.mutex.lock();
        self.connection_pool.destroy(@alignCast(connection));
        self.mutex.unlock();
        // Don't access connection after destroying it
    }
}

/// Get a connection by socket fd
fn getConnection(self: *Engine, fd: posix.socket_t) ?*Connection {
    return self.connections.get(fd);
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
    return self.listener_socket;
}

pub fn getAcceptAddress(self: *Self) std.Io.net.IpAddress {
    return self.listener_address;
}

pub fn getPort(self: *Self) u16 {
    return self.listener_address.getPort();
}

pub fn getAddress(self: *Self) std.Io.net.IpAddress {
    return self.listener_address;
}

/// Shutdown the server.
pub fn shutdown(self: *Self, timeout_ns: u64) void {
    _ = timeout_ns; // TODO: Implement timeout
    // Set stopping flag to exit event loop
    if (!self.stopping.isSet()) {
        self.stopping.set();
    }

    // Close listener socket to wake up any blocking operations (like kevent)
    // This is important to unblock aio_io.run() which may be waiting on kevent
    const listener = self.getSocket();
    if (listener >= 0) {
        posix.close(listener);
        self.listener_socket = -1;
    }

    // Broadcast to wake up any waiting threads
    self.cond.broadcast();

    // Signal stopped
    if (!self.stopped.isSet()) {
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

// Aio callback functions

fn acceptCallback(
    engine: *Engine,
    completion: *IO.Completion,
    result: IO.AcceptError!posix.socket_t,
) void {
    _ = completion;

    if (result) |fd| {
        // Handle successful accept
        // Removed log to avoid interfering with test runner
        engine.handleAcceptedConnection(fd);

        // Accept new connection
        engine.startAccept(engine.getSocket()) catch |err| {
            if (!engine.stopping.isSet()) {
                std.log.err("Failed to start accepting new connections: {}", .{err});
            }
        };
    } else |err| {
        // Handle accept error - don't log if engine is stopping
        if (!engine.stopping.isSet()) {
            std.log.err("Accept error: {}", .{err});
        }

        // Restart accepting new connections
        engine.startAccept(engine.getSocket()) catch |err2| {
            if (!engine.stopping.isSet()) {
                std.log.err("Failed to restart accepting after error: {}", .{err2});
            }
        };
    }
}

fn readCallback(
    engine: *Engine,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    const bytes_read = result catch {
        // Handle read error - just close the connection
        const connection = engine.getConnection(completion.operation.recv.socket);
        if (connection) |conn| {
            engine.closeConnection(conn);
        }
        return;
    };

    // Handle successful read
    if (bytes_read > 0) {
        // Get the connection from the completion
        const connection = engine.getConnection(completion.operation.recv.socket);
        if (connection) |conn| {
            engine.handleReadCompletion(conn, engine.read_buffer[0..bytes_read]);
        }
    } else {
        // Connection closed by peer
        const connection = engine.getConnection(completion.operation.recv.socket);
        if (connection) |conn| {
            engine.closeConnection(conn);
        }
    }
}

fn writeCallback(
    engine: *Engine,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    const bytes_written = result catch {
        // Handle write error - free buffer and close connection
        const connection = engine.getConnection(completion.operation.send.socket);
        if (connection) |conn| {
            // Free the write buffer on error
            if (conn.write_buffer) |buffer| {
                engine.allocator.free(buffer);
                conn.write_buffer = null;
            }
            engine.closeConnection(conn);
        }
        return;
    };

    // Handle successful write
    // Get the connection from the completion
    const connection = engine.getConnection(completion.operation.send.socket);
    if (connection) |conn| {
        engine.handleWriteCompletion(conn, bytes_written);
    }
}
