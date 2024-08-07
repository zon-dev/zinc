const std = @import("std");

const RespondOptions = std.http.Server.Request.RespondOptions;
const Header = std.http.Header;

const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Config = @import("config.zig").Config;
const Headers = @import("headers.zig").Headers;

pub const Context = @This();
const Self = @This();

request: *Request,
response: *Response,

headers: Headers = Headers.init(),

// params: std.StringHashMap(anyopaque) = std.StringHashMap(anyopaque).init(std.heap.page_allocator),

pub fn init(self: Self) Context {
    return Context{
        .request = self.request,
        .response = self.response,
    };
}

pub fn HTML(self: *Self, conf: Config.Context, content: []const u8) anyerror!void {
    try self.headers.add("Content-Type", "text/html");
    try self.closedResponse(conf, content);
}

pub fn Text(self: *Self, conf: Config.Context, content: []const u8) anyerror!void {
    try self.headers.add("Content-Type", "text/plain");
    try self.closedResponse(conf, content);
}

pub fn JSON(self: *Self, conf: Config.Context, value: anytype) anyerror!void {
    var buf: [100]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var string = std.ArrayList(u8).init(fba.allocator());
    try std.json.stringify(value, .{}, string.writer());
    try self.headers.add("Content-Type", "application/json");

    try self.closedResponse(conf, string.items);
}

fn closedResponse(self: *Self, conf: Config.Context, content: []const u8) anyerror!void {
    try self.response.send(content, .{
        .status = conf.status,
        .extra_headers = self.headers.items(),
        .keep_alive = false,
    });
}

pub fn addHeader(self: *Self, name: []const u8, value: []const u8) anyerror!void {
    try self.headers.add(name, value);
}

pub fn getHeaders(self: *Self) *Headers {
    return &self.headers;
}

pub fn next(self: *Self) !void {
    _ = self;
}

pub fn redirect(self: *Self,http_status: std.http.Status ,url: []const u8) anyerror!void {
    try self.headers.add("Location", url);
    self.response.status = http_status;
    try self.request.*.request.respond("", .{
        .status = self.response.status,
        .extra_headers = self.headers.items(),
        .keep_alive = false,
    });
}