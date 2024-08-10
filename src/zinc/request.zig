const std = @import("std");
const http = std.http;
const mem = std.mem;
const http_request = std.http.Server.Request;
const RespondOptions = http_request.RespondOptions;

pub const Request = @This();
const Self = @This();

request: *http_request,

pub fn init(self: Self) Request {
    return .{
        .request = self.request,
    };
}

pub fn method(self: *Request) http.Method {
    return self.request.head.method;
}

pub fn send(self: *Request, content: []const u8, options: RespondOptions) !void {
    try self.request.respond(content, options);
}

// pub fn sendJson(self: *Request, content: []const u8) !void {
//     const options = .{ .status = .ok, .content_type = "application/json", .keep_alive = true };
//     try self.send(content, options);
// }

// pub fn sendFile(self: *Request, path: []const u8) !void {
//     const options = .{ .status = .ok, .content_type = "application/octet-stream", .keep_alive = true };
//     try self.request.reader().sendFile(path, options);
// }
