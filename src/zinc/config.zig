const std = @import("std");

pub const Config = @This();

pub const Engine = struct {
    /// The server address. Default is "0.0.0.0" which means all interfaces.
    addr: []const u8 = "0.0.0.0",
    /// The server port. Default is 0. This means the server will choose a random port.
    port: u16 = 0,

    /// The allocator to use.
    /// Default is the std.heap.page_allocator.
    allocator: std.mem.Allocator = std.heap.page_allocator,

    /// The buffer length for the read buffer. Default is 32KB for maximum performance.
    read_buffer_len: usize = 32 * 1024,
    /// The buffer length for the header. Default is 4KB for maximum performance.
    header_buffer_len: usize = 4 * 1024,
    /// The buffer length for the body. Default is 32KB for maximum performance.
    body_buffer_len: usize = 32 * 1024,

    /// The stack_size in bytes is the stack of each thread.
    /// Default is 10MB.
    /// This is only used when the `.num_threads` is greater than 1.
    stack_size: usize = 10 * 1024 * 1024,

    /// The number of threads to use. Maximum is 255.
    /// Increased to 32 for maximum performance.
    num_threads: u8 = 32,

    /// The maximum number of connections to accept.
    /// Default is 10000.
    max_conn: u32 = 10000,

    /// Target number of concurrent accept operations per thread.
    /// Default is 32.
    target_concurrent_accepts: usize = 32,

    /// AIO queue depth. Default is 4095.
    /// This controls the maximum number of concurrent I/O operations.
    aio_queue_depth: usize = 4095,

    /// Initial read buffer pool size per thread.
    /// Default is calculated based on max_conn and num_threads, capped at 500.
    initial_read_buffers_per_thread: ?usize = null,

    /// Maximum read buffer pool size per thread (as multiplier of initial).
    /// Default is 4 (4x initial size).
    max_read_buffers_multiplier: usize = 4,

    /// Maximum initial read buffers per thread (cap).
    /// Default is 500.
    max_initial_read_buffers: usize = 500,

    /// Write buffer size in bytes. Default is 8KB.
    write_buffer_size: usize = 8 * 1024,

    /// Initial write buffer pool size per thread (as ratio of read buffers).
    /// Default is 0.5 (half of read buffers).
    initial_write_buffers_ratio: f64 = 0.5,

    /// Maximum initial write buffers per thread (cap).
    /// Default is 250.
    max_initial_write_buffers: usize = 250,

    /// Maximum write buffer pool size per thread (as multiplier of initial).
    /// Default is 4 (4x initial size).
    max_write_buffers_multiplier: usize = 4,

    /// Arena allocator retain limit in bytes. Default is 128KB.
    /// Arena will retain this much memory after reset to reduce allocations.
    arena_retain_limit: usize = 128 * 1024,

    /// Number of requests before resetting arena allocator. Default is 100.
    /// Resetting arena periodically helps prevent memory growth.
    arena_reset_interval: usize = 100,

    /// Event loop wait timeout in nanoseconds. Default is 1ms.
    /// Too short timeout causes excessive CPU usage.
    /// Too long timeout causes high latency.
    event_wait_timeout_ns: u63 = 1 * std.time.ns_per_ms,

    /// Request batch size for Thread.Pool processing. Default is 100.
    /// Batching requests reduces Thread.Pool spawn overhead.
    request_batch_size: usize = 100,

    /// Minimum batch size to submit immediately. Default is 10.
    /// If batch reaches this size, submit immediately even if not full.
    /// This reduces latency for small batches while still benefiting from batching.
    request_min_batch_size: usize = 1000,

    ///
    tick_ms: u63 = 10,

    /// Data of any arbitrary type that will be passed down to each Context
    data: *anyopaque = undefined,
};

pub fn appData(self: *Engine, data: anytype) void {
    self.data = data;
}

pub const Context = struct {
    status: std.http.Status = std.http.Status.ok,
    keep_alive: bool = false,
};
