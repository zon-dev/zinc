const std = @import("std");
const http = std.http;
const mem = std.mem;
const server_request = std.http.Server.Request;
const RespondOptions = server_request.RespondOptions;

pub const Request = @This();
const Self = @This();

allocator: std.mem.Allocator = std.heap.page_allocator,
server_request: *server_request = undefined,

header: std.StringArrayHashMap([]u8) = std.StringArrayHashMap([]u8).init(std.heap.page_allocator),
status: http.Status = http.Status.ok,
target: []const u8 = "",
method: http.Method = undefined,

pub fn init(self: Self) Request {
    if (self.target.len > 0) {
        return .{
            .allocator = self.allocator,
            .target = self.target,
            .header = self.header,
        };
    }
    return .{
        .header = self.header,
        .allocator = self.allocator,
        .server_request = self.server_request,
        .target = self.server_request.head.target,
        .method = self.server_request.head.method,
    };
}

pub fn send(self: *Request, content: []const u8, options: RespondOptions) !void {
    try self.server_request.respond(content, options);
}

pub fn setHeader(self: *Request, key: []const u8, value: []const u8) void {
    self.header.put(key, value);
}

pub fn getHeader(self: *Request, key: []const u8) ?[]const u8 {
    return self.header.get(key);
}

pub fn setStatus(self: *Request, status: http.Status) void {
    self.status = status;
}
