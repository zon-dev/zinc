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

headers: Headers = Headers.init(.{}),

params: std.StringHashMap(Param) = std.StringHashMap(Param).init(std.heap.page_allocator),

query: ?std.Uri.Component = null,

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

pub fn html(self: *Self, content: []const u8, conf: Config.Context) anyerror!void {
    try self.headers.add("Content-Type", "text/html");
    try self.closedResponse(
        content,
        conf,
    );
}

pub fn text(self: *Self, content: []const u8, conf: Config.Context) anyerror!void {
    try self.headers.add("Content-Type", "text/plain");
    try self.closedResponse(
        content,
        conf,
    );
}

pub fn json(self: *Self, value: anytype, conf: Config.Context) anyerror!void {
    var buf: [100]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var string = std.ArrayList(u8).init(fba.allocator());
    try std.json.stringify(value, .{}, string.writer());
    try self.headers.add("Content-Type", "application/json");

    try self.closedResponse(string.items, conf);
}

pub fn send(self: *Self, content: []const u8, options: RespondOptions) anyerror!void {
    try self.response.send(content, options);
}

pub fn file(
    self: *Self,
    file_path: []const u8,
    conf: Config.Context,
) anyerror!void {
    var f = try std.fs.cwd().openFile(file_path, .{});
    defer f.close();

    // Read the file into a buffer.
    const stat = try f.stat();
    const buffer = try f.readToEndAlloc(self.allocator, stat.size);
    defer self.allocator.free(buffer);

    try self.closedResponse(buffer, conf);
}

pub fn dir(self: *Self, dir_name: []const u8, conf: Config.Context) anyerror!void {
    const target = self.request.request.head.target;

    // const target_dir = std.fs.path.dirname(target).?;
    const target_file = std.fs.path.basename(target);

    var targets = std.mem.splitSequence(u8, target, "/");

    // Todo, ????
    _ = targets.first();

    var dirs = std.mem.splitSequence(u8, dir_name, targets.next().?);

    var sub_path: []u8 = undefined;
    if (dirs.buffer.len > 0) {
        sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dirs.first(), target });
    } else {
        sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_name, target_file });
    }

    var f = try std.fs.cwd().openFile(sub_path, .{});
    defer f.close();

    // Read the file into a buffer.
    const stat = try f.stat();
    const buffer = try f.readToEndAlloc(self.allocator, stat.size);
    defer self.allocator.free(buffer);

    try self.closedResponse(buffer, conf);
}

pub fn getParam(self: *Self, key: []const u8) ?Param {
    return self.params.get(key);
}

pub fn setStatus(self: *Self, status: std.http.Status) !void {
    self.response.status = status;
}

pub fn sendBody(self: *Self, body: []const u8) anyerror!void {
    try self.response.sendBody(body);
}

fn closedResponse(self: *Self, content: []const u8, conf: Config.Context) anyerror!void {
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

pub fn queryMap() !void {}

pub fn postFormMap() !void {}

pub fn postForm() !void {}
