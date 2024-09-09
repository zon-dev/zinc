const std = @import("std");
const http = std.http;
const Server = http.Server;
const Status = http.Status;
const page_allocator = std.heap.page_allocator;

const server_request = Server.Request;
const server_response = Server.Response;
const RespondOptions = server_request.RespondOptions;

const Config = @import("config.zig").Config;

pub const Response = @This();
const Self = @This();

allocator: std.mem.Allocator = page_allocator,
req: *server_request = undefined,
res: *server_response = undefined,

version: []const u8 = "HTTP/1.1",
status: std.http.Status = .ok,
header: std.StringArrayHashMap([]u8) = undefined,

body: ?[]const u8 = null,

body_buffer_len: usize = 1024,

pub fn init(self: Self) Response {
    // var body_buffer: []u8 = "";
    // if (self.body != null) {
    //     body_buffer = self.allocator.alloc(u8, self.body_buffer_len) catch unreachable;
    //     std.mem.copyForwards(u8, body_buffer, self.body.?);
    // }
    return .{
        .allocator = self.allocator,
        .req = self.req,
        .res = self.res,
        .version = self.version,
        .status = self.status,
        .header = std.StringArrayHashMap([]u8).init(self.allocator),
        // .body = body_buffer,
        .body = self.body,
        .body_buffer_len = self.body_buffer_len,
    };
}

pub fn send(self: *Self, content: []const u8, options: RespondOptions) anyerror!void {
    // TODO handler panic error
    try self.req.respond(content, options);
}

pub fn setStatus(self: *Self, status: std.http.Status) void {
    self.status = status;
}

pub fn setHeader(self: *Self, key: []const u8, value: []const u8) void {
    self.header.put(key, value);
}

pub fn setBody(self: *Self, body: []const u8) anyerror!void {
    // TODO
    // if (self.body != null) {
    //     var new_body: []u8 = undefined;
    //     new_body = try std.heap.page_allocator.alloc(u8, self.body_buffer_len);
    //     new_body = try std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ self.body.?, body });
    //     self.body = new_body;
    //     return;
    // }

    self.body = body;
}

pub fn sendStatus(self: *Self, status: Status) server_response.WriteError!void {
    self.status = status;
    return try self.req.respond(self.body, .{ .status = status });
}
