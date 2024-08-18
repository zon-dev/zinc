const std = @import("std");
const http = std.http;
const mem = std.mem;
const server_request = std.http.Server.Request;
const RespondOptions = server_request.RespondOptions;

pub const Request = @This();
const Self = @This();

request: *server_request,

// target:[]const u8 = Self.request.head.target,
target: []const u8 = undefined,

pub fn init(self: Self) Request {
    return .{
        .request = self.request,
        .target = self.request.head.target,
    };
}

pub fn method(self: *Request) http.Method {
    return self.request.head.method;
}

pub fn send(self: *Request, content: []const u8, options: RespondOptions) !void {
    try self.request.respond(content, options);
}
