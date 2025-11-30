const std = @import("std");
const http = std.http;
const Status = http.Status;

const RespondOptions = std.http.Server.Request.RespondOptions;

const Config = @import("config.zig").Config;

pub const Response = @This();
const Self = @This();

const zinc = @import("../zinc.zig");
const IO = zinc.AIO.IO;

allocator: std.mem.Allocator,
// conn: std.net.Stream = undefined,
conn: std.posix.socket_t = undefined,

// TODO
// io: *IO = undefined,
completion: IO.Completion = undefined,

// Engine and connection for async operations
engine: ?*anyopaque = null, // Will be cast to *Engine when needed
connection: ?*anyopaque = null, // Will be cast to *Engine.Connection when needed

req_method: ?http.Method = undefined,

version: []const u8 = "HTTP/1.1",
status: std.http.Status = .ok,
header: std.array_list.Managed(std.http.Header) = undefined,

body: ?[]const u8 = null,

body_buffer_len: usize = 1024,

pub fn init(self: Self) anyerror!*Response {
    const response = try self.allocator.create(Response);
    response.* = .{
        .allocator = self.allocator,
        .header = std.array_list.Managed(std.http.Header).init(self.allocator),
        .conn = self.conn,
        // .io = self.io,
    };
    return response;
}

pub fn deinit(self: *Self) void {
    if (self.body != null) {
        self.allocator.free(self.body.?);
    }
    self.header.deinit();

    const allocator = self.allocator;
    allocator.destroy(self);
}

/// Reset the response object for reuse in object pool
/// Clears headers, body, and resets fields to default values
/// Note: Header ArrayList is not cleared here to avoid API issues
/// Headers will be overwritten on next use, which is safe for object pool
pub fn reset(self: *Self) void {
    if (self.body) |body| {
        self.allocator.free(body);
        self.body = null;
    }
    // Don't clear header ArrayList - it will be overwritten on next use
    // Clearing ArrayList requires iterating which can be expensive
    // For object pool, we can just reset the fields
    self.status = .ok;
    self.req_method = undefined;
    self.engine = null;
    self.connection = null;
}
pub fn send(self: *Self, content: []const u8, options: RespondOptions) anyerror!void {
    // Use async write if engine and connection are available
    if (self.engine) |engine_ptr| {
        if (self.connection) |conn_ptr| {
            return self.sendAsync(content, options, engine_ptr, conn_ptr);
        }
    }

    // Fallback to synchronous write for backward compatibility
    const req_method = self.req_method.?;

    const transfer_encoding_none = (options.transfer_encoding orelse .chunked) == .none;
    const keep_alive = !transfer_encoding_none and options.keep_alive;
    const phrase = options.reason orelse options.status.phrase() orelse "";

    var first_buffer: [500]u8 = undefined;
    var h = std.ArrayListUnmanaged(u8).initBuffer(&first_buffer);

    var status_line_buffer: [64]u8 = undefined;
    const status_line = std.fmt.bufPrint(&status_line_buffer, "{s} {d} {s}\r\n", .{
        @tagName(options.version), @intFromEnum(options.status), phrase,
    }) catch unreachable;
    h.appendSliceAssumeCapacity(status_line);

    switch (options.version) {
        .@"HTTP/1.0" => if (keep_alive) h.appendSliceAssumeCapacity("connection: keep-alive\r\n"),
        .@"HTTP/1.1" => if (!keep_alive) h.appendSliceAssumeCapacity("connection: close\r\n"),
    }

    if (options.transfer_encoding) |transfer_encoding| switch (transfer_encoding) {
        .none => {},
        .chunked => h.appendSliceAssumeCapacity("transfer-encoding: chunked\r\n"),
    } else {
        var content_length_buffer: [32]u8 = undefined;
        const content_length_line = std.fmt.bufPrint(&content_length_buffer, "content-length: {d}\r\n", .{content.len}) catch unreachable;
        h.appendSliceAssumeCapacity(content_length_line);
    }

    var chunk_header_buffer: [18]u8 = undefined;
    const max_extra_headers = 25;
    var iovecs: [max_extra_headers * 4 + 3]std.posix.iovec_const = undefined;
    var iovecs_len: usize = 0;

    iovecs[iovecs_len] = .{
        .base = h.items.ptr,
        .len = h.items.len,
    };
    iovecs_len += 1;

    for (options.extra_headers) |header| {
        iovecs[iovecs_len] = .{
            .base = header.name.ptr,
            .len = header.name.len,
        };
        iovecs_len += 1;

        iovecs[iovecs_len] = .{
            .base = ": ",
            .len = 2,
        };
        iovecs_len += 1;

        if (header.value.len != 0) {
            iovecs[iovecs_len] = .{
                .base = header.value.ptr,
                .len = header.value.len,
            };
            iovecs_len += 1;
        }

        iovecs[iovecs_len] = .{
            .base = "\r\n",
            .len = 2,
        };
        iovecs_len += 1;
    }

    iovecs[iovecs_len] = .{
        .base = "\r\n",
        .len = 2,
    };
    iovecs_len += 1;

    if (req_method != .HEAD) {
        const is_chunked = (options.transfer_encoding orelse .none) == .chunked;
        if (is_chunked) {
            if (content.len > 0) {
                const chunk_header = std.fmt.bufPrint(
                    &chunk_header_buffer,
                    "{x}\r\n",
                    .{content.len},
                ) catch unreachable;

                iovecs[iovecs_len] = .{
                    .base = chunk_header.ptr,
                    .len = chunk_header.len,
                };
                iovecs_len += 1;

                iovecs[iovecs_len] = .{
                    .base = content.ptr,
                    .len = content.len,
                };
                iovecs_len += 1;

                iovecs[iovecs_len] = .{
                    .base = "\r\n",
                    .len = 2,
                };
                iovecs_len += 1;
            }

            iovecs[iovecs_len] = .{
                .base = "0\r\n\r\n",
                .len = 5,
            };
            iovecs_len += 1;
        } else if (content.len > 0) {
            iovecs[iovecs_len] = .{
                .base = content.ptr,
                .len = content.len,
            };
            iovecs_len += 1;
        }
    }

    // Fallback to synchronous write for backward compatibility
    _ = try std.posix.writev(self.conn, iovecs[0..iovecs_len]);
}

/// Async version of send that uses AIO for non-blocking response writing
fn sendAsync(self: *Self, content: []const u8, options: RespondOptions, engine_ptr: *anyopaque, conn_ptr: *anyopaque) anyerror!void {
    // Cast to proper types
    const Engine = @import("../zinc.zig").Engine;
    const engine: *Engine = @ptrCast(@alignCast(engine_ptr));
    const connection: *Engine.Connection = @ptrCast(@alignCast(conn_ptr));
    const req_method = self.req_method.?;

    const transfer_encoding_none = (options.transfer_encoding orelse .chunked) == .none;
    const keep_alive = !transfer_encoding_none and options.keep_alive;
    const phrase = options.reason orelse options.status.phrase() orelse "";

    // Build response using stack buffer first, then allocate only what we need
    var stack_buffer: [2048]u8 = undefined;
    var h = std.ArrayListUnmanaged(u8).initBuffer(&stack_buffer);

    // Build status line
    var status_line_buffer: [64]u8 = undefined;
    const status_line = std.fmt.bufPrint(&status_line_buffer, "{s} {d} {s}\r\n", .{
        @tagName(options.version), @intFromEnum(options.status), phrase,
    }) catch unreachable;
    h.appendSliceAssumeCapacity(status_line);

    // Build connection header
    switch (options.version) {
        .@"HTTP/1.0" => if (keep_alive) h.appendSliceAssumeCapacity("connection: keep-alive\r\n"),
        .@"HTTP/1.1" => if (!keep_alive) h.appendSliceAssumeCapacity("connection: close\r\n"),
    }

    // Build content-length or transfer-encoding header
    if (options.transfer_encoding) |transfer_encoding| switch (transfer_encoding) {
        .none => {},
        .chunked => h.appendSliceAssumeCapacity("transfer-encoding: chunked\r\n"),
    } else {
        var content_length_buffer: [32]u8 = undefined;
        const content_length_line = std.fmt.bufPrint(&content_length_buffer, "content-length: {d}\r\n", .{content.len}) catch unreachable;
        h.appendSliceAssumeCapacity(content_length_line);
    }

    // Add extra headers
    for (options.extra_headers) |header| {
        h.appendSliceAssumeCapacity(header.name);
        h.appendSliceAssumeCapacity(": ");
        if (header.value.len > 0) {
            h.appendSliceAssumeCapacity(header.value);
        }
        h.appendSliceAssumeCapacity("\r\n");
    }

    h.appendSliceAssumeCapacity("\r\n");

    // Calculate total size needed
    const header_size = h.items.len;
    const body_size = if (req_method != .HEAD) content.len else 0;
    const total_size = header_size + body_size;

    // Get worker from connection for buffer pool access
    const worker = connection.worker orelse {
        // Fallback: allocate directly if worker not set (shouldn't happen)
        const response_data = try engine.allocator.alloc(u8, total_size);
        errdefer engine.allocator.free(response_data);
        @memcpy(response_data[0..header_size], h.items);
        if (body_size > 0) {
            @memcpy(response_data[header_size..][0..body_size], content);
        }
        engine.startWrite(connection, response_data) catch |err| {
            engine.allocator.free(response_data);
            return err;
        };
        return;
    };

    // Try to get buffer from write buffer pool (much faster than allocation)
    var response_data = worker.write_buffer_pool.acquire() catch {
        // Pool exhausted or buffer too small - allocate directly
        // This should be rare if pool is sized correctly
        const fallback_buffer = try engine.allocator.alloc(u8, total_size);
        errdefer engine.allocator.free(fallback_buffer);
        @memcpy(fallback_buffer[0..header_size], h.items);
        if (body_size > 0) {
            @memcpy(fallback_buffer[header_size..][0..body_size], content);
        }
        engine.startWrite(connection, fallback_buffer) catch |err2| {
            engine.allocator.free(fallback_buffer);
            return err2;
        };
        return;
    };

    // Check if buffer is large enough
    if (response_data.len < total_size) {
        // Buffer too small - return to pool and allocate larger one
        worker.write_buffer_pool.release(response_data);
        const large_buffer = try engine.allocator.alloc(u8, total_size);
        errdefer engine.allocator.free(large_buffer);
        @memcpy(large_buffer[0..header_size], h.items);
        if (body_size > 0) {
            @memcpy(large_buffer[header_size..][0..body_size], content);
        }
        engine.startWrite(connection, large_buffer) catch |err| {
            engine.allocator.free(large_buffer);
            return err;
        };
        return;
    }

    // Use the buffer from pool (will be returned to pool in writeCallback)
    @memcpy(response_data[0..header_size], h.items);
    if (body_size > 0) {
        @memcpy(response_data[header_size..][0..body_size], content);
    }

    // Use AIO to send the response asynchronously
    engine.startWrite(connection, response_data[0..total_size]) catch |err| {
        worker.write_buffer_pool.release(response_data);
        return err;
    };
}

pub fn write(self: *Self, content: []const u8, options: RespondOptions) anyerror!void {
    const req_method = self.req_method.?;

    const transfer_encoding_none = (options.transfer_encoding orelse .chunked) == .none;
    const keep_alive = !transfer_encoding_none and options.keep_alive;
    const phrase = options.reason orelse options.status.phrase() orelse "";

    var first_buffer: [500]u8 = undefined;
    var h = std.ArrayListUnmanaged(u8).initBuffer(&first_buffer);
    // if (request.head.expect != null) {
    //     // reader() and hence discardBody() above sets expect to null if it
    //     // is handled. So the fact that it is not null here means unhandled.
    //     h.appendSliceAssumeCapacity("HTTP/1.1 417 Expectation Failed\r\n");
    //     if (!keep_alive) h.appendSliceAssumeCapacity("connection: close\r\n");
    //     h.appendSliceAssumeCapacity("content-length: 0\r\n\r\n");
    //     try request.server.connection.stream.writeAll(h.items);
    //     return;
    // }

    var status_line_buffer: [64]u8 = undefined;
    const status_line = std.fmt.bufPrint(&status_line_buffer, "{s} {d} {s}\r\n", .{
        @tagName(options.version), @intFromEnum(options.status), phrase,
    }) catch unreachable;
    h.appendSliceAssumeCapacity(status_line);

    switch (options.version) {
        .@"HTTP/1.0" => if (keep_alive) h.appendSliceAssumeCapacity("connection: keep-alive\r\n"),
        .@"HTTP/1.1" => if (!keep_alive) h.appendSliceAssumeCapacity("connection: close\r\n"),
    }

    if (options.transfer_encoding) |transfer_encoding| switch (transfer_encoding) {
        .none => {},
        .chunked => h.appendSliceAssumeCapacity("transfer-encoding: chunked\r\n"),
    } else {
        var content_length_buffer: [32]u8 = undefined;
        const content_length_line = std.fmt.bufPrint(&content_length_buffer, "content-length: {d}\r\n", .{content.len}) catch unreachable;
        h.appendSliceAssumeCapacity(content_length_line);
    }

    var chunk_header_buffer: [18]u8 = undefined;
    const max_extra_headers = 25;
    var iovecs: [max_extra_headers * 4 + 3]std.posix.iovec_const = undefined;
    var iovecs_len: usize = 0;

    iovecs[iovecs_len] = .{
        .base = h.items.ptr,
        .len = h.items.len,
    };
    iovecs_len += 1;

    for (options.extra_headers) |header| {
        iovecs[iovecs_len] = .{
            .base = header.name.ptr,
            .len = header.name.len,
        };
        iovecs_len += 1;

        iovecs[iovecs_len] = .{
            .base = ": ",
            .len = 2,
        };
        iovecs_len += 1;

        if (header.value.len != 0) {
            iovecs[iovecs_len] = .{
                .base = header.value.ptr,
                .len = header.value.len,
            };
            iovecs_len += 1;
        }

        iovecs[iovecs_len] = .{
            .base = "\r\n",
            .len = 2,
        };
        iovecs_len += 1;
    }

    iovecs[iovecs_len] = .{
        .base = "\r\n",
        .len = 2,
    };
    iovecs_len += 1;

    if (req_method != .HEAD) {
        const is_chunked = (options.transfer_encoding orelse .none) == .chunked;
        if (is_chunked) {
            if (content.len > 0) {
                const chunk_header = std.fmt.bufPrint(
                    &chunk_header_buffer,
                    "{x}\r\n",
                    .{content.len},
                ) catch unreachable;

                iovecs[iovecs_len] = .{
                    .base = chunk_header.ptr,
                    .len = chunk_header.len,
                };
                iovecs_len += 1;

                iovecs[iovecs_len] = .{
                    .base = content.ptr,
                    .len = content.len,
                };
                iovecs_len += 1;

                iovecs[iovecs_len] = .{
                    .base = "\r\n",
                    .len = 2,
                };
                iovecs_len += 1;
            }

            iovecs[iovecs_len] = .{
                .base = "0\r\n\r\n",
                .len = 5,
            };
            iovecs_len += 1;
        } else if (content.len > 0) {
            iovecs[iovecs_len] = .{
                .base = content.ptr,
                .len = content.len,
            };
            iovecs_len += 1;
        }
    }
    // try self.conn.write(iovecs[0..iovecs_len]);
    _ = try std.posix.writev(self.conn, iovecs[0..iovecs_len]);
}

pub fn setStatus(self: *Self, status: std.http.Status) void {
    self.status = status;
}

fn ensureHeaderInitialized(self: *Self) !void {
    // Header is always initialized in init(), so this is a no-op
    _ = self;
}

pub fn setHeader(self: *Self, key: []const u8, value: []const u8) anyerror!void {
    try self.ensureHeaderInitialized();
    try self.header.append(.{ .name = key, .value = value });
}

pub fn getHeaders(self: *Self) []std.http.Header {
    return self.header.items;
}

pub fn isKeepAlive(self: *Self) bool {
    for (self.header.items) |header| {
        // If the connection header is set to close, then the connection should be closed.
        if (std.ascii.eqlIgnoreCase(header.name, "Connection") and std.ascii.eqlIgnoreCase(header.value, "close")) {
            return false;
        }
    }

    return true;
}

pub fn setBody(self: *Self, body: []const u8) anyerror!void {
    // Free old body if exists
    if (self.body) |old_body| {
        self.allocator.free(old_body);
        self.body = null; // Clear before allocating new one
    }

    // Allocate and copy new body
    const slice = try self.allocator.dupe(u8, body);
    self.body = slice;
}

/// Append to existing body (for middleware chain support)
pub fn appendBody(self: *Self, content: []const u8) anyerror!void {
    if (self.body) |existing_body| {
        // Append mode: concatenate with existing body
        const new_body = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ existing_body, content });
        self.allocator.free(existing_body);
        self.body = new_body;
    } else {
        // No existing body, just set it
        const slice = try self.allocator.dupe(u8, content);
        self.body = slice;
    }
}

pub fn sendStatus(self: *Self, status: Status) anyerror!void {
    self.status = status;
    const body = self.body orelse "";
    return try self.send(body, .{
        .status = self.status,
        .extra_headers = self.header.items,
    });
}
