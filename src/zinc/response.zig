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
// header: std.StringArrayHashMap([]u8) = undefined,
header: std.ArrayList(std.http.Header) = undefined,

body: ?[]const u8 = null,

body_buffer_len: usize = 1024,

pub fn init(self: Self) Response {
    return .{
        .allocator = self.allocator,
        .req = self.req,
        .res = self.res,
        .version = self.version,
        .status = self.status,
        .header = std.ArrayList(std.http.Header).init(self.allocator),
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

pub fn setHeader(self: *Self, key: []const u8, value: []const u8) anyerror!void {
    try self.header.append(.{ .name = key, .value = value });
}

pub fn setBody(self: *Self, body: []const u8) anyerror!void {
    var new_body = std.ArrayList(u8).init(self.allocator);
    // defer self.allocator.free(new_body.items);

    const old_body = self.body orelse "";
    try new_body.appendSlice(old_body);
    try new_body.appendSlice(body);
    const slice = try new_body.toOwnedSlice();

    self.body = slice;
}

pub fn sendStatus(self: *Self, status: Status) server_response.WriteError!void {
    self.status = status;
    const body = self.body orelse "";
    return try self.req.respond(body, .{
        .status = self.status,
        .extra_headers = self.header.items,
    });
}
