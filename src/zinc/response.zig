const std = @import("std");
const http = std.http;
const Server = http.Server;
const Status = http.Status;

const server_request = Server.Request;
const server_response = Server.Response;
const RespondOptions = server_request.RespondOptions;

const Config = @import("config.zig").Config;

pub const Response = @This();
const Self = @This();

allocator: std.mem.Allocator,
req: *server_request = undefined,
res: *server_response = undefined,

version: []const u8 = "HTTP/1.1",
status: std.http.Status = .ok,
header: std.ArrayList(std.http.Header) = undefined,

body: ?[]const u8 = null,

body_buffer_len: usize = 1024,

pub fn init(self: Self) anyerror!*Response {
    const response = try self.allocator.create(Response);
    response.* = .{
        .allocator = self.allocator,
        .req = self.req,
        .res = self.res,
        .header = std.ArrayList(std.http.Header).init(self.allocator),
    };
    return response;
}

pub fn deinit(self: *Self) void {
    if (self.body != null) {
        self.allocator.free(self.body.?);
    }
    if (self.header.items.len > 0) {
        self.header.deinit();
    }
    self.allocator.destroy(self);
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

pub fn getHeaders(self: *Self) []std.http.Header {
    return self.header.items;
}

pub fn setBody(self: *Self, body: []const u8) anyerror!void {
    var new_body = std.ArrayList(u8).init(self.allocator);
    defer self.allocator.free(new_body.items);

    if (self.body) |old_body| {
        defer self.allocator.free(old_body);
        try new_body.appendSlice(old_body);
    }

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
