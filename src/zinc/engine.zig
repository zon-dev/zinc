const std = @import("std");

const http = std.http;
const posix = std.posix;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Set-once flag replacing std.Thread.ResetEvent, which Zig 0.17 removed.
/// Only the set/isSet subset the engine uses is provided; there is no wait().
const Flag = struct {
    state: std.atomic.Value(bool),

    const unset: Flag = .{ .state = .init(false) };

    fn set(f: *Flag) void {
        f.state.store(true, .release);
    }

    fn isSet(f: *const Flag) bool {
        return f.state.load(.acquire);
    }
};

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

/// Zig 0.17 removed the thin `std.posix` syscall wrappers; `posix_compat` restores
/// the subset the engine needs for the descriptors it owns directly.
const compat = @import("posix_compat.zig");

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

    /// Non-null while a send is in flight. The bytes live in `arena`, so this is
    /// an in-flight marker, not an owning pointer — never free it directly.
    write_buffer: ?[]u8 = null,

    // Each connection has its own read buffer from the pool
    read_buffer: ?[]u8 = null,

    /// Per-connection scratch. The request/response objects, everything the
    /// handler allocates, and the serialized response bytes all come from here.
    /// Reset once the response has been written (`handleWriteCompletionWorker`),
    /// which is the only point at which nothing from the exchange is still live:
    /// the send is asynchronous, so the response bytes must outlive `handleConn`.
    ///
    /// Per-connection rather than per-worker precisely because of that overlap —
    /// one connection's send can still be in flight while another connection on
    /// the same worker is being handled, so a shared arena could not be reset
    /// safely. `retain_with_limit` keeps the first chunk, so steady-state request
    /// handling performs no allocator syscalls at all.
    arena: std.heap.ArenaAllocator = undefined,

    // Store reference to worker for fast lookup (avoid scanning all workers)
    // This is set when connection is created and never changes
    worker: ?*Worker = null,

    pub fn init(allocator: Allocator) Connection {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
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

    /// Id of the thread running this worker's event loop. Requests are handled
    /// inline on that thread, so every aio submission for a connection this
    /// worker owns must come from it; `assertOnWorkerThread` checks that in Debug.
    thread_id: std.Thread.Id = 0,

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
                connection.arena.deinit();
                allocator.destroy(connection);
            }
        }
        self.connections.deinit(allocator);

        // Close listener
        if (self.listener_socket >= 0) {
            compat.close(self.listener_socket);
        }

        // Deinit resources
        self.aio_io.deinit();
        self.read_buffer_pool.deinit();
        self.write_buffer_pool.deinit();

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
// Zig 0.17 removed std.Thread.Pool in favour of std.Io; `io_impl` owns the
// worker threads and `task_group` replaces the old pool's fire-and-forget spawn.
io_impl: std.Io.Threaded = undefined,
task_group: std.Io.Group = .init,
stopping: Flag = .unset,
stopped: Flag = .unset,

/// see at https://github.com/ziglang/zig/blob/master/lib/std/Thread/Condition.zig
cond: Io.Condition = .init,
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

// Arena allocator configuration
arena_retain_limit: usize = 128 * 1024,
arena_reset_interval: usize = 100,

// Event loop configuration
event_wait_timeout_ns: u63 = 1 * std.time.ns_per_ms,

// Worker threads (each has its own resources)
workers: []Worker = undefined,
worker_threads: ?[]std.Thread = null, // null if threads haven't been started yet
threads_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
        .io_impl = undefined,
        .num_threads = conf.num_threads,
        .stack_size = conf.stack_size,
        .listener_address = address, // Will be updated after first listener is created
        .max_conn = conf.max_conn,
        .target_concurrent_accepts = conf.target_concurrent_accepts,
        .arena_retain_limit = conf.arena_retain_limit,
        .arena_reset_interval = conf.arena_reset_interval,
        .event_wait_timeout_ns = conf.event_wait_timeout_ns,
        .workers = undefined,
        .worker_threads = undefined,
    };

    // Handlers run inline on the AIO worker threads; this pool exists only
    // because Engine still needs a `std.Io` for condition broadcast / sleep.
    engine.io_impl = std.Io.Threaded.init(allocator, .{
        .stack_size = conf.stack_size,
        .concurrent_limit = .limited(1),
    });
    engine.task_group = .init;

    // Create workers for each thread
    // Each worker has its own IO instance, listener socket, and resources
    engine.workers = try allocator.alloc(Worker, conf.num_threads);
    errdefer allocator.free(engine.workers);

    // worker_threads will be allocated when run() is called

    // Initialize each worker with its own resources
    for (engine.workers, 0..) |*worker, i| {
        // Each thread gets its own listener socket with SO_REUSEPORT
        // This allows the kernel to distribute connections across threads
        const listener = try server.listen(address, .{
            .reuse_address = true,
            .reuse_port = true, // Critical for multi-threading
        });

        // Update listener_address from first listener (they all bind to same address)
        if (i == 0) {
            engine.listener_address = listener.listen_address;
        }

        // Each thread has its own IO instance (required for thread safety)
        // IO.init expects u12, so we need to clamp the value
        const aio_queue_depth: u12 = @intCast(@min(conf.aio_queue_depth, 4095));
        const aio_io = try IO.init(aio_queue_depth, 0);
        const aio_time = Time{};

        // Initialize worker
        worker.* = Worker{
            .aio_io = aio_io,
            .aio_time = aio_time,
            .listener_socket = listener.socket_fd,
            .engine = engine,
        };

        // Initialize buffer pools for this worker
        // Use adaptive sizing based on max_conn and num_threads
        // Calculate reasonable buffer counts to avoid excessive memory usage
        // For high thread counts, use smaller initial pools that can grow as needed
        const estimated_conns_per_thread = @max(engine.max_conn / conf.num_threads, 100);

        // Calculate initial read buffers per thread
        const initial_read_buffers = if (conf.initial_read_buffers_per_thread) |count|
            count
        else
            @min(estimated_conns_per_thread, conf.max_initial_read_buffers);
        const max_read_buffers = initial_read_buffers * conf.max_read_buffers_multiplier;

        worker.read_buffer_pool = try BufferPool.init(
            allocator,
            conf.read_buffer_len,
            initial_read_buffers,
            max_read_buffers,
        );

        // Write buffer pool: calculate based on read buffers ratio
        const initial_write_buffers = @min(@as(usize, @intFromFloat(@as(f64, @floatFromInt(initial_read_buffers)) * conf.initial_write_buffers_ratio)), conf.max_initial_write_buffers);
        const max_write_buffers = initial_write_buffers * conf.max_write_buffers_multiplier;

        worker.write_buffer_pool = try BufferPool.init(
            allocator,
            conf.write_buffer_size,
            initial_write_buffers,
            max_write_buffers,
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
    self.cond.broadcast(self.io_impl.io());

    // Close test connection if any (not needed with new API)

    // Listeners are closed in worker.deinit()

    // Wait for worker threads to finish (if they were started)
    // Only join if threads were actually started and run() hasn't completed yet
    if (self.threads_started.load(.acquire)) {
        if (self.worker_threads) |threads| {
            // Give threads a moment to check stopping flag and exit
            self.io_impl.io().sleep(.fromMilliseconds(50), .awake) catch {};
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

    // Wait for in-flight request tasks, then tear down the thread pool.
    self.task_group.cancel(self.io_impl.io());
    self.io_impl.deinit();

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

    worker.thread_id = std.Thread.getCurrentId();

    // Pre-start multiple accept operations for high concurrency
    for (0..engine.target_concurrent_accepts) |_| {
        startAcceptWorker(worker, listener) catch |err| {
            if (!engine.stopping.isSet()) {
                std.log.err("Failed to start accept operation: {}", .{err});
            }
        };
    }

    // Event loop. Requests are handled inline in the read completion callback and
    // the response is submitted to aio from this same thread, so there is nothing
    // to drain between iterations — a completed read runs the handler and queues
    // the send within one `run_for_ns` pass. `event_wait_timeout_ns` therefore only
    // bounds how quickly the loop notices `stopping`; it is not in the request path.
    while (!engine.stopping.isSet()) {
        worker.aio_io.run_for_ns(engine.event_wait_timeout_ns) catch |err| {
            if (err != error.TimeoutTooBig and !engine.stopping.isSet()) {
                std.log.err("AIO run_for_ns error: {}", .{err});
            }
        };
    }
}

/// Requests run inline on the worker's event-loop thread, so aio submissions for
/// a connection must happen there. Cheap enough to leave in Debug only.
inline fn assertOnWorkerThread(worker: *Worker) void {
    if (std.debug.runtime_safety and worker.thread_id != 0) {
        std.debug.assert(std.Thread.getCurrentId() == worker.thread_id);
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

/// Start reading from a connection (worker version)
fn startReadWorker(worker: *Worker, connection: *Connection) !void {
    assertOnWorkerThread(worker);

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

/// Start writing to a connection (worker version).
///
/// Small responses almost always fit in the TCP send buffer. A non-blocking
/// `write` here completes the exchange without waiting for another kevent
/// cycle — that extra wait was a ~100µs floor (~5–10k req/s per connection).
///
/// On a full send, `write_buffer` is cleared and the caller (`handleReadCompletionWorker`
/// or `handleWriteCompletionWorker`) re-arms the read. Resetting the arena here
/// would free memory `handleConn` is still using.
fn startWriteWorker(worker: *Worker, connection: *Connection, data: []const u8) !void {
    assertOnWorkerThread(worker);

    connection.write_buffer = @constCast(data);

    if (compat.write(connection.fd, data)) |written| {
        if (written >= data.len) {
            connection.write_buffer = null;
            return;
        }
        if (written > 0) {
            const rest = data[written..];
            connection.write_buffer = @constCast(rest);
            worker.aio_io.send(
                *Worker,
                worker,
                writeCallbackWorker,
                &connection.write_completion,
                connection.fd,
                rest,
            );
            return;
        }
    } else |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    }

    worker.aio_io.send(
        *Worker,
        worker,
        writeCallbackWorker,
        &connection.write_completion,
        connection.fd,
        data,
    );
}

/// Submit a response for an owned connection.
///
/// `data` must stay valid until the write completes; callers allocate it from
/// `connection.arena`, which is reset once the send is done. Must be called on
/// the connection's worker thread — which holds because handlers run inline
/// in the read completion callback.
pub fn startWrite(self: *Engine, connection: *Connection, data: []const u8) !void {
    const worker = connection.worker orelse {
        for (self.workers) |*w| {
            if (w.connections.get(connection.fd)) |_| {
                connection.setWorker(w);
                return startWriteWorker(w, connection, data);
            }
        }
        return error.ConnectionNotFound;
    };

    return startWriteWorker(worker, connection, data);
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
        compat.close(client_fd);
        return;
    }

    // Darwin `accept()` does not inherit O_NONBLOCK; Nagle delays tiny responses.
    compat.setNonblock(client_fd);
    compat.setTcpNoDelay(client_fd);

    // Create new connection
    const connection = allocator.create(Connection) catch |err| {
        std.log.warn("Failed to allocate connection: {}", .{err});
        compat.close(client_fd);
        return;
    };
    connection.* = Connection.init(allocator);
    connection.setSocket(client_fd);
    connection.state = .connected;

    // Acquire read buffer from pool
    // acquire() always succeeds now (allows dynamic growth)
    connection.read_buffer = worker.read_buffer_pool.acquire() catch |err| {
        std.log.err("Critical: Failed to allocate read buffer: {}", .{err});
        connection.arena.deinit();
        allocator.destroy(connection);
        compat.close(client_fd);
        return;
    };

    // Set worker reference for fast lookup (avoid scanning all workers in startWrite)
    connection.setWorker(worker);

    // Add to managed connections
    worker.connections.put(allocator, client_fd, connection) catch |err| {
        std.log.warn("Failed to add connection to map: {}", .{err});
        if (connection.read_buffer) |buffer| {
            worker.read_buffer_pool.release(buffer);
        }
        connection.arena.deinit();
        allocator.destroy(connection);
        compat.close(client_fd);
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
    _ = self;
    _ = client_fd;
    @compileError("handleAcceptedConnection should not be called in multi-threaded mode");
}

/// Handle read completion: run the request inline on this worker thread.
///
/// `data` points straight into `connection.read_buffer`, which stays valid for
/// the whole call — the next `recv` is only armed after the response has been
/// written. So the request is parsed in place with no copy.
///
/// Everything the exchange allocates comes from `connection.arena`, including the
/// serialized response, which must outlive this function if the send is
/// asynchronous. The arena is reset once the write completes.
fn handleReadCompletionWorker(worker: *Worker, connection: *Connection, data: []u8) void {
    const engine = worker.engine;
    if (data.len == 0) {
        closeConnectionWorker(worker, connection);
        return;
    }

    engine.router.handleConn(
        connection.arena.allocator(),
        connection.getSocket(),
        data,
        engine,
        connection,
    ) catch |err| {
        catchRouteError(err, connection.getSocket()) catch |err2| {
            std.log.err("Failed to handle route error: {}", .{err2});
        };
        closeConnectionWorker(worker, connection);
        return;
    };

    // Inline send completed inside `handleConn`. Re-arm here so the arena is
    // not reset while request/response objects on that arena are still live.
    if (connection.write_buffer == null) {
        _ = connection.arena.reset(.{ .retain_with_limit = engine.arena_retain_limit });
        startReadWorker(worker, connection) catch |err| {
            std.log.err("Failed to continue reading: {}", .{err});
            closeConnectionWorker(worker, connection);
        };
    }
}

/// Handle write completion: release the exchange's memory and re-arm the read.
///
/// This is the one point where nothing from the request/response is still live
/// for an async send, so it is where `connection.arena` is reset.
fn handleWriteCompletionWorker(worker: *Worker, connection: *Connection, bytes_written: usize) void {
    const engine = worker.engine;

    if (connection.write_buffer) |buffer| {
        // Short write: submit the remainder before touching the arena — `buffer`
        // still points into it. aio's send maps to a single syscall, so a partial
        // write is possible for a large response even on loopback.
        if (bytes_written < buffer.len) {
            const rest = buffer[bytes_written..];
            startWriteWorker(worker, connection, rest) catch |err| {
                std.log.err("Failed to continue partial write: {}", .{err});
                closeConnectionWorker(worker, connection);
            };
            return;
        }
        connection.write_buffer = null;
    }

    _ = connection.arena.reset(.{ .retain_with_limit = engine.arena_retain_limit });

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
        const fd = connection.fd;

        // Close socket first - this will cancel any pending operations
        // Note: close_socket should handle cleanup of pending operations
        worker.aio_io.close_socket(fd);
        _ = worker.connections.remove(fd);

        // Decrement connection count
        _ = engine.connection_count.fetchSub(1, .monotonic);

        // Return read buffer to pool
        if (connection.read_buffer) |buffer| {
            worker.read_buffer_pool.release(buffer);
            connection.read_buffer = null;
        }

        // `write_buffer` is arena memory, not a pooled buffer — it used to be
        // released to `write_buffer_pool`, which never owned it. Dropping the
        // marker is enough; `arena.deinit()` below frees the bytes.
        connection.write_buffer = null;
        connection.arena.deinit();

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
    _ = self;
    _ = retain_size;
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
    self.cond.broadcast(self.io_impl.io());

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
    // Verify completion operation type before accessing
    if (completion.operation != .recv) {
        std.log.err("readCallbackWorker: completion operation is not recv", .{});
        return;
    }

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
    // Verify completion operation type before accessing
    if (completion.operation != .send) {
        std.log.err("writeCallbackWorker: completion operation is not send", .{});
        return;
    }

    const bytes_written = result catch {
        const connection = getConnectionWorker(worker, completion.operation.send.socket);
        if (connection) |conn| {
            conn.write_buffer = null;
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
