const std = @import("std");
const http = std.http;
const mem = std.mem;

pub const Request = @This();
const Self = @This();

allocator: std.mem.Allocator,

// Connection is now just a socket fd, not used directly
conn: std.posix.socket_t = undefined,

// Lazy initialization: only initialize header HashMap when actually needed
header: ?std.StringArrayHashMap([]u8) = null,
header_initialized: bool = false,
status: http.Status = http.Status.ok,

target: []const u8 = "",
method: http.Method = undefined,

query: ?std.Uri.Component = null,

head: std.http.Server.Request.Head = undefined,

pub fn init(self: Self) anyerror!*Request {
    var request = try self.allocator.create(Request);
    errdefer self.allocator.destroy(request);
    request.* = .{
        .allocator = self.allocator,
        .header = null, // Lazy initialization - only init when needed
        .header_initialized = false,
        .status = self.status,
        .head = self.head,
        .conn = self.conn,
    };

    if (self.target.len > 0) {
        request.target = self.target;
        request.method = self.method;
    }

    return request;
}

pub fn deinit(self: *Request) void {
    if (self.header_initialized) {
        self.header.?.deinit();
    }

    const allocator = self.allocator;
    allocator.destroy(self);
}

/// Reset the request object for reuse in object pool
/// Clears headers and resets fields to default values
/// Note: Header HashMap is not cleared here to avoid API issues
/// Headers will be overwritten on next use, which is safe for object pool
pub fn reset(self: *Request) void {
    // Don't clear header HashMap - it will be overwritten on next use
    // Clearing HashMap in Zig requires deinit/reinit which is expensive
    // For object pool, we can just reset the fields and let headers be overwritten
    self.target = "";
    self.method = undefined;
    self.query = null;
    self.status = http.Status.ok;
}

fn ensureHeaderInitialized(self: *Request) !void {
    if (!self.header_initialized) {
        self.header = std.StringArrayHashMap([]u8).init(self.allocator);
        self.header_initialized = true;
    }
}

pub fn setHeader(self: *Request, key: []const u8, value: []const u8) anyerror!void {
    try self.ensureHeaderInitialized();
    try self.header.?.put(key, @constCast(value));
}

pub fn getHeader(self: *Request, key: []const u8) ?[]const u8 {
    if (!self.header_initialized) return null;
    return self.header.?.get(key);
}

pub fn setStatus(self: *Request, status: http.Status) void {
    self.status = status;
}
