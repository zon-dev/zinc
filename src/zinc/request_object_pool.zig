const std = @import("std");
const Allocator = std.mem.Allocator;

const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;

/// HTTP request object pool for reusing Request/Response/Context objects
/// Reduces memory allocations by reusing objects across HTTP requests
pub fn RequestObjectPool(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        available: std.array_list.Managed(*T),
        mutex: std.Thread.Mutex,
        total_allocated: usize = 0,
        max_objects: usize,
        init_fn: *const fn (Allocator) anyerror!*T,
        reset_fn: ?*const fn (*T) void,

        /// Initialize a new pool
        pub fn init(
            allocator: Allocator,
            max_objects: usize,
            init_fn: *const fn (Allocator) anyerror!*T,
            reset_fn: ?*const fn (*T) void,
        ) !Self {
            return Self{
                .allocator = allocator,
                .available = std.array_list.Managed(*T).init(allocator),
                .mutex = .{},
                .max_objects = max_objects,
                .init_fn = init_fn,
                .reset_fn = reset_fn,
            };
        }

        /// Acquire an object from the pool
        pub fn acquire(self: *Self) !*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Try to get an object from the pool
            if (self.available.items.len > 0) {
                const obj = self.available.orderedRemove(self.available.items.len - 1);
                // Reset object if reset function is provided
                if (self.reset_fn) |reset| {
                    reset(obj);
                }
                return obj;
            }

            // Pool is empty, allocate a new object if we haven't reached max
            if (self.total_allocated < self.max_objects) {
                const obj = try self.init_fn(self.allocator);
                self.total_allocated += 1;
                return obj;
            }

            // Max objects reached, allocate anyway but log a warning
            std.log.warn("RequestObjectPool exhausted, allocating new object beyond max limit", .{});
            return try self.init_fn(self.allocator);
        }

        /// Release an object back to the pool
        pub fn release(self: *Self, obj: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Check if pool is full (prevent unbounded growth)
            if (self.available.items.len >= self.max_objects) {
                // Pool is full, don't add more objects
                // Reset and let the object be destroyed by the caller
                if (self.reset_fn) |reset| {
                    reset(obj);
                }
                return;
            }

            // Return object to pool
            self.available.append(obj) catch {
                // If we can't add to pool, reset the object
                if (self.reset_fn) |reset| {
                    reset(obj);
                }
            };
        }

        /// Deinitialize the pool
        /// Note: This does NOT destroy the objects in the pool
        /// Caller must destroy objects before calling deinit
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.available.deinit();
        }
    };
}

/// Request object pool for HTTP requests
pub const RequestPool = RequestObjectPool(Request);

/// Response object pool for HTTP requests
pub const ResponsePool = RequestObjectPool(Response);

/// Context object pool for HTTP requests
pub const ContextPool = RequestObjectPool(Context);

// Helper functions for creating pools

fn createRequest(allocator: Allocator) anyerror!*Request {
    return try Request.init(.{
        .allocator = allocator,
        .target = "",
        .method = undefined,
    });
}

fn createResponse(allocator: Allocator) anyerror!*Response {
    return try Response.init(.{
        .allocator = allocator,
        .conn = -1,
    });
}

fn createContext(allocator: Allocator) anyerror!*Context {
    // Context requires request and response, so we need to create them first
    // This is a limitation - we might need a different approach
    _ = allocator;
    return error.ContextRequiresRequestAndResponse;
}

/// Initialize request pool
pub fn initRequestPool(allocator: Allocator, max_objects: usize) !RequestPool {
    return try RequestPool.init(allocator, max_objects, createRequest, Request.reset);
}

/// Initialize response pool
pub fn initResponsePool(allocator: Allocator, max_objects: usize) !ResponsePool {
    return try ResponsePool.init(allocator, max_objects, createResponse, Response.reset);
}
