const std = @import("std");
const Allocator = std.mem.Allocator;

/// Buffer pool for managing read buffers
/// Lock-free implementation for single-threaded event loop
pub const BufferPool = struct {
    allocator: Allocator,
    buffer_size: usize,
    available: std.array_list.Managed([]u8),
    // Removed mutex - single-threaded event loop, no locking needed
    total_allocated: usize = 0,
    max_buffers: usize,

    /// Initialize a new buffer pool
    pub fn init(allocator: Allocator, buffer_size: usize, initial_count: usize, max_buffers: usize) !BufferPool {
        var pool = BufferPool{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .available = std.array_list.Managed([]u8).init(allocator),
            .max_buffers = max_buffers,
        };

        // Pre-allocate initial buffers
        for (0..initial_count) |_| {
            const buffer = try allocator.alloc(u8, buffer_size);
            try pool.available.append(buffer);
            pool.total_allocated += 1;
        }

        return pool;
    }

    /// Acquire a buffer from the pool
    /// Returns a buffer from the pool if available, or allocates a new one
    /// Lock-free implementation for single-threaded event loop
    /// Always succeeds - allows dynamic growth beyond max_buffers to handle bursts
    pub fn acquire(self: *BufferPool) ![]u8 {
        // No mutex needed - single-threaded event loop

        // Try to get a buffer from the pool (pop from the end)
        if (self.available.items.len > 0) {
            return self.available.orderedRemove(self.available.items.len - 1);
        }

        // Pool is empty, allocate a new buffer
        // Allow dynamic growth beyond max_buffers to handle connection bursts
        // This prevents connection rejections during high load
        const buffer = try self.allocator.alloc(u8, self.buffer_size);
        self.total_allocated += 1;

        // Log warning only if we significantly exceed the soft limit
        // This helps identify when buffer pool sizing needs adjustment
        if (self.total_allocated > self.max_buffers and
            self.total_allocated % 100 == 0)
        { // Log every 100 buffers to avoid spam
            std.log.warn("Buffer pool exceeded soft limit: {}/{} buffers allocated", .{ self.total_allocated, self.max_buffers });
        }

        return buffer;
    }

    /// Release a buffer back to the pool
    /// Lock-free implementation for single-threaded event loop
    pub fn release(self: *BufferPool, buffer: []u8) void {
        // No mutex needed - single-threaded event loop

        // Return buffer to pool
        self.available.append(buffer) catch {
            // If we can't add to pool (shouldn't happen), just free the buffer
            self.allocator.free(buffer);
        };
    }

    /// Deinitialize the buffer pool and free all buffers
    /// Lock-free implementation for single-threaded event loop
    pub fn deinit(self: *BufferPool) void {
        // No mutex needed - single-threaded event loop

        // Free all buffers in the pool
        for (self.available.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.available.deinit();
    }
};
