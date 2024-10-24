const std = @import("std");
const http = std.http;
const mem = std.mem;

pub const Request = @This();
const Self = @This();

allocator: std.mem.Allocator,

conn: std.net.Server.Connection = undefined,

header: std.StringArrayHashMap([]u8) = undefined,
status: http.Status = http.Status.ok,

target: []const u8 = "",
method: http.Method = undefined,

query: ?std.Uri.Component = null,

pub fn init(self: Self) anyerror!*Request {
    var request = try self.allocator.create(Request);
    errdefer self.allocator.destroy(request);
    request.* = .{
        .allocator = self.allocator,
        .header = std.StringArrayHashMap([]u8).init(self.allocator),
        .status = self.status,

        .conn = self.conn,
    };

    if (self.target.len > 0) {
        request.target = self.target;
        request.method = self.method;
    }

    return request;
}

pub fn deinit(self: *Request) void {
    self.header.deinit();

    self.allocator.destroy(self);
}

pub fn setHeader(self: *Request, key: []const u8, value: []const u8) anyerror!void {
    try self.header.put(key, @constCast(value));
}

pub fn getHeader(self: *Request, key: []const u8) ?[]const u8 {
    return self.header.get(key);
}

pub fn setStatus(self: *Request, status: http.Status) void {
    self.status = status;
}
