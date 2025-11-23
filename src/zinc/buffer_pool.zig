const std = @import("std");
const Allocator = std.mem.Allocator;

/// Buffer pool for managing read buffers
/// Uses a mutex-protected ArrayList for thread-safe buffer management
pub const BufferPool = struct {
    allocator: Allocator,
    buffer_size: usize,
    available: std.array_list.Managed([]u8),
    mutex: std.Thread.Mutex,
    total_allocated: usize = 0,
    max_buffers: usize,

    /// Initialize a new buffer pool
    pub fn init(allocator: Allocator, buffer_size: usize, initial_count: usize, max_buffers: usize) !BufferPool {
        var pool = BufferPool{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .available = std.array_list.Managed([]u8).init(allocator),
            .mutex = .{},
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
    /// Returns a buffer from the pool if available, or allocates a new one if under max limit
    pub fn acquire(self: *BufferPool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to get a buffer from the pool (pop from the end)
        if (self.available.items.len > 0) {
            return self.available.orderedRemove(self.available.items.len - 1);
        }

        // Pool is empty, allocate a new buffer if we haven't reached max
        if (self.total_allocated < self.max_buffers) {
            const buffer = try self.allocator.alloc(u8, self.buffer_size);
            self.total_allocated += 1;
            return buffer;
        }

        // Max buffers reached, wait for one to become available
        // In practice, this should rarely happen if max_buffers is set correctly
        // For now, we'll allocate anyway but log a warning
        std.log.warn("Buffer pool exhausted, allocating new buffer beyond max limit", .{});
        return try self.allocator.alloc(u8, self.buffer_size);
    }

    /// Release a buffer back to the pool
    pub fn release(self: *BufferPool, buffer: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Return buffer to pool
        self.available.append(buffer) catch {
            // If we can't add to pool (shouldn't happen), just free the buffer
            self.allocator.free(buffer);
        };
    }

    /// Deinitialize the buffer pool and free all buffers
    pub fn deinit(self: *BufferPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free all buffers in the pool
        for (self.available.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.available.deinit();
    }
};
