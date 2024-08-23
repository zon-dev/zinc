const std = @import("std");
const http = std.http;
const header = http.Header;
const http_request = std.http.Server.Request;
const http_response = std.http.Server.Response;

const RespondOptions = http_request.RespondOptions;
const Config = @import("config.zig").Config;

pub const Response = @This();
const Self = @This();

request: *http_request = undefined,
response: *http_response = undefined,

version: []const u8 = "HTTP/1.1",
status: http.Status = http.Status.ok,
header: std.StringArrayHashMap([]u8) = std.StringArrayHashMap([]u8).init(std.heap.page_allocator),
body: []const u8 = "",

pub fn init(self: Self) Response {
    return .{
        .request = self.request,
        .response = self.response,
        .version = self.version,
        .status = self.status,
        .header = self.header,
        .body = self.body,
    };
}

pub fn send(self: *Self, content: []const u8, options: RespondOptions) http_response.WriteError!void {
    return try self.request.respond(content, options);
}

pub fn sendBody(self: *Self, content: []const u8) !void {
    try self.send(content, .{
        .status = self.status,
        .keep_alive = false,
    });
}
