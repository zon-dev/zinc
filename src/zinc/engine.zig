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
const BufferPool = @import("buffer_pool.zig").BufferPool;

/// Request processing context for async processing
const RequestContext = struct {
    worker: *Worker,
    connection: *Connection,
    data: []u8,
    data_owned: bool, // Whether we own the data buffer (need to free it)
};

// Forward declaration - Connection is defined later
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

    // Each connection has its own read buffer from the pool
    read_buffer: ?[]u8 = null,

    // Store reference to worker for fast lookup (avoid scanning all workers)
    // This is set when connection is created and never changes
    worker: ?*Worker = null,

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

    pub fn setWorker(self: *Connection, w: *Worker) void {
        self.worker = w;
    }
};

// Multi-threaded support: Each thread has its own resources
// Worker context for each thread (contains thread-local resources)
pub const Worker = struct {
    // Each thread has its own IO instance (required for thread safety)
    aio_io: IO = undefined,
    aio_time: Time = undefined,

    // Each thread has its own listener socket (with SO_REUSEPORT)
    listener_socket: posix.socket_t = -1,

    // Each thread has its own connection management
    connections: std.AutoHashMapUnmanaged(posix.socket_t, *Connection) = .{},

    // Each thread has its own buffer pools
    read_buffer_pool: BufferPool = undefined,
    write_buffer_pool: BufferPool = undefined,

    // Each thread has its own accept completions
    accept_completions: []IO.Completion = undefined,
    accept_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // Each thread has its own arena for request processing
    arena: std.heap.ArenaAllocator = undefined,
    arena_request_count: usize = 0,

    // Request queue for async processing (lock-free, single producer)
    // Requests are queued here and processed asynchronously to avoid blocking event loop
    request_queue: std.array_list.Managed(*RequestContext) = undefined,
    request_queue_index: usize = 0, // Index for reading from queue

    // Reference to shared engine (read-only after init)
    engine: *Engine = undefined,

    pub fn deinit(self: *Worker, allocator: Allocator) void {
        // Close all connections
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            const connection = entry.value_ptr.*;
            if (connection.fd != -1) {
                self.aio_io.close_socket(connection.fd);
                if (connection.read_buffer) |buffer| {
                    self.read_buffer_pool.release(buffer);
                }
                allocator.destroy(connection);
            }
        }
        self.connections.deinit(allocator);

        // Close listener
        if (self.listener_socket >= 0) {
            posix.close(self.listener_socket);
        }

        // Deinit resources
        self.aio_io.deinit();
        self.read_buffer_pool.deinit();
        self.write_buffer_pool.deinit();
        self.arena.deinit();

        // Clean up request queue
        for (self.request_queue.items) |ctx| {
            if (ctx.data_owned) {
                allocator.free(ctx.data);
            }
            allocator.destroy(ctx);
        }
        self.request_queue.deinit();

        if (self.accept_completions.len > 0) {
            allocator.free(self.accept_completions);
        }
    }
};

pub const Engine = @This();
const Self = @This();

allocator: Allocator = undefined,

// Shared engine state (read-only after init, safe for multi-threaded access)
// Server state
listener_address: std.Io.net.IpAddress = undefined,

// Global connection count (atomic, lock-free)
connection_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

// Thread management
threads: std.Thread.Pool = undefined,
stopping: std.Thread.ResetEvent = .unset,
stopped: std.Thread.ResetEvent = .unset,

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
middlewares: ?std.array_list.Managed(HandlerFn) = undefined,

/// max connections.
max_conn: u32 = 10000,

// Target number of concurrent accept operations per thread
target_concurrent_accepts: usize = 32,

// Worker threads (each has its own resources)
workers: []Worker = undefined,
worker_threads: ?[]std.Thread = null, // null if threads haven't been started yet
threads_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

// Connection is now defined above (before Worker) to allow RequestContext to reference it

/// Create a new engine.
fn create(conf: Config.Engine) anyerror!*Engine {
    const allocator = conf.allocator;
    const engine = try allocator.create(Engine);
    errdefer allocator.destroy(engine);

    const address = try std.Io.net.IpAddress.parse(conf.addr, conf.port);

    // Initialize shared engine state
    engine.* = Engine{
        .allocator = allocator,
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
        .listener_address = address, // Will be updated after first listener is created
        .max_conn = conf.max_conn,
        .target_concurrent_accepts = 32,
        .workers = undefined,
        .worker_threads = undefined,
    };

    // Initialize thread pool (for potential future use)
    try engine.threads.init(.{
        .allocator = allocator,
        .n_jobs = conf.num_threads,
        .track_ids = false,
        .stack_size = conf.stack_size,
    });

    // Create workers for each thread
    // Each worker has its own IO instance, listener socket, and resources
    engine.workers = try allocator.alloc(Worker, conf.num_threads);
    errdefer allocator.free(engine.workers);

    // worker_threads will be allocated when run() is called

    // Initialize each worker with its own resources
    for (engine.workers, 0..) |*worker, i| {
        // Each thread gets its own listener socket with SO_REUSEPORT
        // This allows the kernel to distribute connections across threads
        var listener = try server.listen(address, .{
            .reuse_address = true,
            .reuse_port = true, // Critical for multi-threading
        });

        // Update listener_address from first listener (they all bind to same address)
        if (i == 0) {
            engine.listener_address = listener.listen_address;
        }

        // Each thread has its own IO instance (required for thread safety)
        const aio_io = try IO.init(4095, 0);
        const aio_time = Time{};

        // Initialize worker
        worker.* = Worker{
            .aio_io = aio_io,
            .aio_time = aio_time,
            .listener_socket = listener.socket_fd,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .request_queue = std.array_list.Managed(*RequestContext).init(allocator),
            .request_queue_index = 0,
            .engine = engine,
        };

        // Initialize buffer pools for this worker
        // Use larger initial size to handle bursts better
        // max_buffers is a soft limit - pool can grow beyond it if needed
        const buffers_per_thread = @max(engine.max_conn / conf.num_threads, 10000); // At least 10000 per thread
        worker.read_buffer_pool = try BufferPool.init(
            allocator,
            conf.read_buffer_len,
            buffers_per_thread, // Initial buffers per thread
            buffers_per_thread * 3, // Soft limit: 3x initial (allows for bursts)
        );
        // Write buffer pool: larger buffers for responses (8KB typical response size)
        // Pre-allocate fewer buffers since responses are typically shorter-lived
        const write_buffer_size = 8 * 1024; // 8KB per write buffer
        const write_buffers_per_thread = @max(buffers_per_thread / 4, 2000); // Fewer write buffers needed
        worker.write_buffer_pool = try BufferPool.init(
            allocator,
            write_buffer_size,
            write_buffers_per_thread, // Initial write buffers
            write_buffers_per_thread * 3, // Soft limit
        );

        // Pre-allocate accept completions for this worker
        worker.accept_completions = try allocator.alloc(IO.Completion, engine.target_concurrent_accepts);
    }

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

    // Listeners are closed in worker.deinit()

    // Wait for worker threads to finish (if they were started)
    // Only join if threads were actually started and run() hasn't completed yet
    if (self.threads_started.load(.acquire)) {
        if (self.worker_threads) |threads| {
            // Give threads a moment to check stopping flag and exit
            std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
            for (threads) |thread| {
                thread.join();
            }
            allocator.free(threads);
            self.worker_threads = null;
        }
        self.threads_started.store(false, .release);
    }

    // Deinit all workers
    if (self.workers.len > 0) {
        for (self.workers) |*worker| {
            worker.deinit(allocator);
        }
        allocator.free(self.workers);
    }

    // Wait for thread pool to finish
    self.threads.deinit();

    // Deinit middlewares
    if (self.middlewares) |*m| m.deinit();

    // Deinit router
    self.router.deinit();

    // Signal stopped
    if (!self.stopped.isSet()) self.stopped.set();

    // Resources are deinitialized in worker.deinit()

    // Destroy engine
    allocator.destroy(self);
}

/// Run the server. This function will block the current thread.
/// Spawns multiple worker threads, each running its own event loop.
/// Each thread has its own IO instance and listener socket (with SO_REUSEPORT).
pub fn run(self: *Engine) !void {
    // Mark threads as started
    self.threads_started.store(true, .release);

    // Allocate worker threads array
    self.worker_threads = try self.allocator.alloc(std.Thread, self.workers.len);
    errdefer {
        self.threads_started.store(false, .release);
        if (self.worker_threads) |threads| {
            self.allocator.free(threads);
            self.worker_threads = null;
        }
    }

    // Spawn worker threads
    for (self.workers, 0..) |*worker, i| {
        self.worker_threads.?[i] = try std.Thread.spawn(.{}, workerThread, .{worker});
    }

    // Wait for all threads to finish
    for (self.worker_threads.?) |thread| {
        thread.join();
    }

    // Free thread array
    self.allocator.free(self.worker_threads.?);
    self.worker_threads = null;
    self.threads_started.store(false, .release);
}

/// Worker thread function - runs in each thread
/// Each thread has its own IO instance, listener socket, and resources
fn workerThread(worker: *Worker) void {
    const engine = worker.engine;
    const listener = worker.listener_socket;

    // Pre-start multiple accept operations for high concurrency
    for (0..engine.target_concurrent_accepts) |_| {
        startAcceptWorker(worker, listener) catch |err| {
            if (!engine.stopping.isSet()) {
                std.log.err("Failed to start accept operation: {}", .{err});
            }
        };
    }

    // Event loop for this worker thread
    // Use longer timeout to allow kernel to batch events and reduce CPU usage
    // Shorter timeout causes too many system calls and can lead to timeouts under load
    while (!engine.stopping.isSet()) {
        const event_wait_timeout_ns: u63 = 10 * std.time.ns_per_ms; // 10ms timeout
        worker.aio_io.run_for_ns(event_wait_timeout_ns) catch |err| {
            if (err != error.TimeoutTooBig and !engine.stopping.isSet()) {
                std.log.err("AIO run_for_ns error: {}", .{err});
            }
        };

        // Process queued requests asynchronously (non-blocking, processes up to 10 per iteration)
        // This allows request processing without blocking the event loop
        var processed: usize = 0;
        const max_per_iteration = 10; // Process up to 10 requests per event loop iteration
        while (processed < max_per_iteration and worker.request_queue_index < worker.request_queue.items.len) {
            const ctx = worker.request_queue.items[worker.request_queue_index];
            worker.request_queue_index += 1;
            processRequestAsync(ctx);
            processed += 1;
        }

        // Reset queue when all items are processed
        if (worker.request_queue_index >= worker.request_queue.items.len) {
            worker.request_queue.clearRetainingCapacity();
            worker.request_queue_index = 0;
        }
    }
}

/// Start accepting connections (worker version)
/// Uses a round-robin approach to distribute accept operations across the completion pool
fn startAcceptWorker(worker: *Worker, socket: posix.socket_t) !void {
    const engine = worker.engine;
    // Use round-robin to distribute accept operations across completion slots
    const index = worker.accept_index.fetchAdd(1, .monotonic) % engine.target_concurrent_accepts;
    const completion = &worker.accept_completions[index];

    worker.aio_io.accept(
        *Worker,
        worker,
        acceptCallbackWorker,
        completion,
        socket,
    );
}

/// Start accepting connections (legacy, kept for compatibility)
fn startAccept(self: *Engine, socket: posix.socket_t) !void {
    _ = self;
    _ = socket;
    @compileError("startAccept should not be called in multi-threaded mode");
}

/// Start reading from a connection (worker version)
fn startReadWorker(worker: *Worker, connection: *Connection) !void {
    // Ensure connection has a read buffer
    if (connection.read_buffer == null) {
        connection.read_buffer = try worker.read_buffer_pool.acquire();
    }

    worker.aio_io.recv(
        *Worker,
        worker,
        readCallbackWorker,
        &connection.read_completion,
        connection.fd,
        connection.read_buffer.?,
    );
}

/// Start reading from a connection (legacy)
fn startRead(self: *Engine, connection: *Connection) !void {
    _ = self;
    _ = connection;
    @compileError("startRead should not be called in multi-threaded mode");
}

/// Start writing to a connection (worker version)
fn startWriteWorker(worker: *Worker, connection: *Connection, data: []const u8) !void {
    connection.write_buffer = @constCast(data);
    worker.aio_io.send(
        *Worker,
        worker,
        writeCallbackWorker,
        &connection.write_completion,
        connection.fd,
        data,
    );
}

/// Start writing to a connection (public API - uses cached worker reference)
pub fn startWrite(self: *Engine, connection: *Connection, data: []const u8) !void {
    // Use cached worker reference for O(1) lookup instead of O(n) scan
    if (connection.worker) |worker| {
        return startWriteWorker(worker, connection, data);
    }
    // Fallback: scan all workers (should rarely happen)
    for (self.workers) |*worker| {
        if (worker.connections.get(connection.fd)) |_| {
            connection.setWorker(worker); // Cache for next time
            return startWriteWorker(worker, connection, data);
        }
    }
    return error.ConnectionNotFound;
}

/// Handle accepted connection (worker version)
fn handleAcceptedConnectionWorker(worker: *Worker, client_fd: posix.socket_t) void {
    const engine = worker.engine;
    const allocator = engine.allocator;

    // Check connection limit with a larger buffer to handle bursts
    // Use a much larger buffer (50% of max_conn) to handle connection bursts and reduce socket errors
    // This is critical for high-throughput scenarios where connections are established rapidly
    const current_connections = engine.connection_count.load(.monotonic);
    const max_with_buffer = engine.max_conn + @max(engine.max_conn / 2, 1000); // 50% buffer, min 1000
    if (current_connections >= max_with_buffer) {
        // Only reject if significantly over limit
        // Log to help diagnose connection rejection issues
        if (current_connections % 1000 == 0) { // Log every 1000 rejections to avoid spam
            std.log.warn("Connection limit reached: {}/{}, rejecting new connection", .{ current_connections, engine.max_conn });
        }
        posix.close(client_fd);
        return;
    }

    // Create new connection
    const connection = allocator.create(Connection) catch |err| {
        std.log.warn("Failed to allocate connection: {}", .{err});
        posix.close(client_fd);
        return;
    };
    connection.* = Connection.init();
    connection.setSocket(client_fd);
    connection.state = .connected;

    // Acquire read buffer from pool
    // acquire() always succeeds now (allows dynamic growth)
    connection.read_buffer = worker.read_buffer_pool.acquire() catch |err| {
        // This should never happen now, but keep error handling for safety
        std.log.err("Critical: Failed to allocate read buffer: {}", .{err});
        allocator.destroy(connection);
        posix.close(client_fd);
        return;
    };

    // Add to managed connections
    worker.connections.put(allocator, client_fd, connection) catch |err| {
        std.log.warn("Failed to add connection to map: {}", .{err});
        if (connection.read_buffer) |buffer| {
            worker.read_buffer_pool.release(buffer);
        }
        allocator.destroy(connection);
        posix.close(client_fd);
        return;
    };

    // Increment connection count AFTER successfully adding to map
    // This ensures we only count connections that are fully established
    const new_count = engine.connection_count.fetchAdd(1, .monotonic) + 1;

    // Double-check limit after increment (in case we exceeded during concurrent accepts)
    // Use a much larger buffer (100% of max_conn) to allow for connection bursts
    // Only close if significantly over limit to avoid unnecessary rejections and socket errors
    if (new_count > engine.max_conn * 2) {
        std.log.warn("Connection limit significantly exceeded: {}/{}, closing new connection", .{ new_count, engine.max_conn });
        closeConnectionWorker(worker, connection);
        return;
    }

    // Start reading
    startReadWorker(worker, connection) catch |err| {
        std.log.warn("Failed to start reading: {}", .{err});
        closeConnectionWorker(worker, connection);
    };
}

/// Handle accepted connection (legacy)
fn handleAcceptedConnection(self: *Engine, client_fd: posix.socket_t) void {
    // Check connection limit before accepting (lock-free atomic check)
    // This prevents resource exhaustion and improves error handling
    const current_connections = self.connection_count.load(.monotonic);
    if (current_connections >= self.max_conn) {
        // Connection limit reached, close immediately
        // This is better than accepting and then closing, which causes errors on client side
        posix.close(client_fd);
        return;
    }

    // Create new connection - no mutex needed, single-threaded event loop
    // Direct allocation is faster than memory pool for single-threaded use
    const connection = self.allocator.create(Connection) catch |err| {
        // Allocation failed - close the socket to avoid client errors
        std.log.warn("Failed to allocate connection: {}", .{err});
        posix.close(client_fd);
        return;
    };
    // Initialize connection with default values
    connection.* = Connection.init();
    connection.setSocket(client_fd);
    connection.state = .connected;

    // Acquire read buffer from pool
    connection.read_buffer = self.read_buffer_pool.acquire() catch |err| {
        // Buffer pool exhausted - clean up and close
        std.log.warn("Read buffer pool exhausted, rejecting new connection: {}", .{err});
        // No mutex needed - single-threaded
        self.allocator.destroy(connection);
        posix.close(client_fd);
        return;
    };

    // Add to managed connections and increment counter
    // Check again after acquiring resources to avoid race conditions
    self.connections.put(self.allocator, client_fd, connection) catch |err| {
        std.log.warn("Failed to add connection to map: {}", .{err});

        // Return read buffer to pool before destroying connection
        if (connection.read_buffer) |buffer| {
            self.read_buffer_pool.release(buffer);
            connection.read_buffer = null;
        }

        // Destroy connection - no mutex needed, single-threaded
        self.allocator.destroy(connection);

        posix.close(client_fd);
        return;
    };

    // Increment connection count (lock-free)
    _ = self.connection_count.fetchAdd(1, .monotonic);

    // Start reading from the connection
    self.startRead(connection) catch |err| {
        std.log.warn("Failed to start reading from connection: {}", .{err});
        self.closeConnection(connection);
    };
}

/// Handle read completion (worker version)
/// Now processes requests asynchronously to avoid blocking the event loop
fn handleReadCompletionWorker(worker: *Worker, connection: *Connection, data: []u8) void {
    const engine = worker.engine;
    if (data.len == 0) {
        closeConnectionWorker(worker, connection);
        return;
    }

    // Reset arena periodically
    worker.arena_request_count += 1;
    if (worker.arena_request_count >= 100) {
        _ = worker.arena.reset(.{ .retain_with_limit = 128 * 1024 });
        worker.arena_request_count = 0;
    }

    // Copy data to owned buffer for async processing
    // This allows the read buffer to be reused immediately
    const data_copy = engine.allocator.alloc(u8, data.len) catch |err| {
        std.log.err("Failed to allocate data copy for async processing: {}", .{err});
        closeConnectionWorker(worker, connection);
        return;
    };
    @memcpy(data_copy, data);

    // Create request context for async processing
    const ctx = engine.allocator.create(RequestContext) catch |err| {
        std.log.err("Failed to allocate request context: {}", .{err});
        engine.allocator.free(data_copy);
        closeConnectionWorker(worker, connection);
        return;
    };
    ctx.* = .{
        .worker = worker,
        .connection = connection,
        .data = data_copy,
        .data_owned = true,
    };

    // Queue request for async processing (non-blocking)
    // This allows the event loop to continue processing other events
    worker.request_queue.append(ctx) catch |err| {
        std.log.err("Failed to queue request for processing: {}", .{err});
        engine.allocator.free(data_copy);
        engine.allocator.destroy(ctx);
        closeConnectionWorker(worker, connection);
        return;
    };

    // Event loop continues immediately - request will be processed in next iteration
    // The read buffer can be reused for the next read operation
}

/// Process HTTP request asynchronously in thread pool
/// This function runs in a worker thread from the thread pool
fn processRequestAsync(ctx: *RequestContext) void {
    const worker = ctx.worker;
    const engine = worker.engine;
    const connection = ctx.connection;
    const data = ctx.data;
    const allocator = engine.allocator;

    // Process HTTP request in background thread
    // Use arena allocator for request-scoped allocations
    engine.router.handleConn(worker.arena.allocator(), connection.getSocket(), data, engine, connection) catch |err| {
        catchRouteError(err, connection.getSocket()) catch |err2| {
            std.log.err("Failed to handle route error: {}", .{err2});
        };
        // Clean up and close connection on error
        allocator.free(data);
        allocator.destroy(ctx);
        closeConnectionWorker(worker, connection);
        return;
    };

    // Clean up request context
    allocator.free(data);
    allocator.destroy(ctx);
}

/// Handle read completion (legacy)
fn handleReadCompletion(self: *Engine, connection: *Connection, data: []u8) void {
    _ = self;
    _ = connection;
    _ = data;
    @compileError("handleReadCompletion should not be called in multi-threaded mode");
}

/// Handle write completion (worker version)
fn handleWriteCompletionWorker(worker: *Worker, connection: *Connection, bytes_written: usize) void {
    _ = bytes_written;
    _ = worker.engine;

    // Return write buffer to pool instead of freeing
    if (connection.write_buffer) |buffer| {
        worker.write_buffer_pool.release(buffer);
        connection.write_buffer = null;
    }

    // Continue reading for keep-alive
    startReadWorker(worker, connection) catch |err| {
        std.log.err("Failed to continue reading: {}", .{err});
        closeConnectionWorker(worker, connection);
    };
}

/// Close a connection (worker version)
fn closeConnectionWorker(worker: *Worker, connection: *Connection) void {
    const engine = worker.engine;
    if (connection.fd != -1) {
        worker.aio_io.close_socket(connection.fd);
        _ = worker.connections.remove(connection.fd);

        // Decrement connection count
        _ = engine.connection_count.fetchSub(1, .monotonic);

        // Return read buffer to pool
        if (connection.read_buffer) |buffer| {
            worker.read_buffer_pool.release(buffer);
            connection.read_buffer = null;
        }

        // Destroy connection
        engine.allocator.destroy(connection);
    }
}

/// Close a connection (legacy)
fn closeConnection(self: *Engine, connection: *Connection) void {
    _ = self;
    _ = connection;
    @compileError("closeConnection should not be called in multi-threaded mode");
}

/// Get a connection by socket fd (worker version)
fn getConnectionWorker(worker: *Worker, fd: posix.socket_t) ?*Connection {
    return worker.connections.get(fd);
}

/// Get a connection by socket fd (legacy)
fn getConnection(self: *Engine, fd: posix.socket_t) ?*Connection {
    _ = self;
    _ = fd;
    @compileError("getConnection should not be called in multi-threaded mode");
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
    // Return first worker's listener socket (all workers share the same port via SO_REUSEPORT)
    if (self.workers.len > 0) {
        return self.workers[0].listener_socket;
    }
    return -1;
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

    // Listeners are closed in worker.deinit()

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

// Aio callback functions - Worker versions for multi-threading

fn acceptCallbackWorker(
    worker: *Worker,
    completion: *IO.Completion,
    result: IO.AcceptError!posix.socket_t,
) void {
    _ = completion;
    const engine = worker.engine;

    if (result) |fd| {
        // Handle successful accept
        handleAcceptedConnectionWorker(worker, fd);

        // Immediately start a new accept to maintain the pool
        startAcceptWorker(worker, worker.listener_socket) catch |err| {
            if (!engine.stopping.isSet()) {
                std.log.err("Failed to start accepting new connections: {}", .{err});
            }
        };
    } else |err| {
        // Handle accept error
        if (!engine.stopping.isSet()) {
            switch (err) {
                error.ConnectionAborted => {
                    // Normal during shutdown or high load
                },
                else => {
                    std.log.err("Accept error: {}", .{err});
                },
            }
        }

        // Restart accepting
        startAcceptWorker(worker, worker.listener_socket) catch |err2| {
            if (!engine.stopping.isSet()) {
                std.log.err("Failed to restart accepting after error: {}", .{err2});
            }
        };
    }
}

// Legacy callback (kept for compatibility, should not be used in multi-threaded mode)
fn acceptCallback(
    engine: *Engine,
    completion: *IO.Completion,
    result: IO.AcceptError!posix.socket_t,
) void {
    _ = engine;
    _ = completion;
    _ = result;
    @compileError("acceptCallback should not be called in multi-threaded mode");
}

fn readCallbackWorker(
    worker: *Worker,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    const bytes_read = result catch {
        // Handle read error
        const connection = getConnectionWorker(worker, completion.operation.recv.socket);
        if (connection) |conn| {
            closeConnectionWorker(worker, conn);
        }
        return;
    };

    // Handle successful read
    if (bytes_read > 0) {
        const connection = getConnectionWorker(worker, completion.operation.recv.socket);
        if (connection) |conn| {
            if (conn.read_buffer) |buffer| {
                handleReadCompletionWorker(worker, conn, buffer[0..bytes_read]);
            } else {
                std.log.err("Connection read_buffer is null", .{});
                closeConnectionWorker(worker, conn);
            }
        }
    } else {
        // Connection closed by peer
        const connection = getConnectionWorker(worker, completion.operation.recv.socket);
        if (connection) |conn| {
            closeConnectionWorker(worker, conn);
        }
    }
}

fn readCallback(
    engine: *Engine,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = engine;
    _ = completion;
    _ = result;
    @compileError("readCallback should not be called in multi-threaded mode");
}

fn writeCallbackWorker(
    worker: *Worker,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    const bytes_written = result catch {
        // Handle write error
        const connection = getConnectionWorker(worker, completion.operation.send.socket);
        if (connection) |conn| {
            if (conn.write_buffer) |buffer| {
                // Return buffer to pool (release always succeeds)
                // If buffer is not from pool, it will be freed by the pool's release logic
                worker.write_buffer_pool.release(buffer);
                conn.write_buffer = null;
            }
            closeConnectionWorker(worker, conn);
        }
        return;
    };

    // Handle successful write
    const connection = getConnectionWorker(worker, completion.operation.send.socket);
    if (connection) |conn| {
        handleWriteCompletionWorker(worker, conn, bytes_written);
    }
}

fn writeCallback(
    engine: *Engine,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = engine;
    _ = completion;
    _ = result;
    @compileError("writeCallback should not be called in multi-threaded mode");
}
