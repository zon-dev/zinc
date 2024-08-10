const std = @import("std");

const RespondOptions = std.http.Server.Request.RespondOptions;
const Header = std.http.Header;

const Request = @import("request.zig");
const Response = @import("response.zig");
const Config = @import("config.zig");
const Headers = @import("headers.zig");
const Param = @import("param.zig");

pub const Context = @This();
const Self = @This();

allocator: std.mem.Allocator = std.heap.page_allocator,
request: *Request = undefined,
response: *Response = undefined,
headers: Headers = Headers.init(),

params: std.StringHashMap(Param) = std.StringHashMap(Param).init(std.heap.page_allocator),

pub fn deinit(self: *Self) void {
    self.headers.deinit();
    self.params.deinit();
}

pub fn init(self: Self) Context {
    if (self.request == undefined and self.response == undefined) {
        @panic("Request and Response are required");
    }

    return Context{
        .request = self.request,
        .response = self.response,
        .headers = self.headers,
        .allocator = self.allocator,
        .params = self.params,
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

pub fn redirect(self: *Self, http_status: std.http.Status, url: []const u8) anyerror!void {
    try self.headers.add("Location", url);
    try self.request.request.respond("", .{ .status = http_status, .reason = http_status.phrase(), .extra_headers = self.headers.items(), .keep_alive = false });
}
