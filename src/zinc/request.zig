const std = @import("std");
const http = std.http;
const mem = std.mem;
const http_request = std.http.Server.Request;
const RespondOptions = http_request.RespondOptions;

request: *http_request,

pub const Request = @This();

pub fn init(req: *http_request) Request {
    return Request{
        .request = req,
    };
}

pub fn getMethod(self: *Request) http.Method {
    return self.request.head.method;
}

pub fn send(self: *Request, content: []const u8, options: RespondOptions) !void {
    try self.request.respond(content, options);
}
