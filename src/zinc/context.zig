const std = @import("std");
const URL = @import("url");
const RespondOptions = std.http.Server.Request.RespondOptions;
const Header = std.http.Header;

const Request = @import("request.zig");
const Response = @import("response.zig");
const Config = @import("config.zig");
const Headers = @import("headers.zig");
const Param = @import("param.zig");

const HandlerFn = @import("handler.zig").HandlerFn;

pub const Context = @This();
const Self = @This();

allocator: std.mem.Allocator = std.heap.page_allocator,

// connection: std.net.Server.Connection = undefined,
request: *Request = undefined,
response: *Response = undefined,

headers: Headers = Headers.init(.{}),

query: ?std.Uri.Component = null,
params: std.StringHashMap(Param) = std.StringHashMap(Param).init(std.heap.page_allocator),

query_map: ?std.StringHashMap(std.ArrayList([]const u8)) = null,

// Slice of optional function pointers
handlers: std.ArrayList(*const fn (*Self) anyerror!void) = std.ArrayList(*const fn (*Self) anyerror!void).init(std.heap.page_allocator),
index: u8 = 0, // Adjust the type based on your specific needs
// index: usize = 0, // Adjust the type based on your specific needs

// body_buffer_len: usize = 0,
// query: ?std.Uri.Component = null,

pub fn deinit(self: *Self) void {
    self.headers.deinit();
    self.params.deinit();
    if (self.query_map != null) {
        self.query_map.?.deinit();
    }
}

pub fn init(self: Self) ?Context {
    if (self.request == undefined and self.response == undefined) {
        return null;
    }

    return Context{
        .request = self.request,
        .response = self.response,
        .headers = self.headers,
        .allocator = self.allocator,
        .params = self.params,
        .query = self.query,
        .query_map = self.query_map,
    };
}

pub fn html(self: *Self, content: []const u8, conf: Config.Context) anyerror!void {
    try self.headers.add("Content-Type", "text/html");
    try self.resp(
        content,
        conf,
    );
}

pub fn text(self: *Self, content: []const u8, conf: Config.Context) anyerror!void {
    try self.headers.add("Content-Type", "text/plain");
    try self.resp(
        content,
        conf,
    );
}

pub fn json(self: *Self, value: anytype, conf: Config.Context) anyerror!void {
    var string = std.ArrayList(u8).init(self.allocator);
    try std.json.stringify(value, .{}, string.writer());
    try self.headers.add("Content-Type", "application/json");

    try self.resp(string.items, conf);
}

pub fn send(self: *Self, content: []const u8, options: RespondOptions) anyerror!void {
    try self.response.send(content, options);
}

pub fn file(
    self: *Self,
    file_path: []const u8,
    conf: Config.Context,
) anyerror!void {
    if (std.fs.path.basename(file_path).len == 0) {
        try self.headers.add("Content-Type", "text/plain");
        try self.resp("404 Not Found", conf);
        return error.NotFound;
    }

    var f = try std.fs.cwd().openFile(file_path, .{});
    defer f.close();

    // Read the file into a buffer.
    const stat = try f.stat();
    const buffer = try f.readToEndAlloc(self.allocator, stat.size);
    defer self.allocator.free(buffer);
    try self.resp(buffer, conf);
}

pub fn dir(self: *Self, dir_name: []const u8, conf: Config.Context) anyerror!void {
    const target = self.request.target;

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

    var f = std.fs.cwd().openFile(sub_path, .{}) catch |err| {
        try self.headers.add("Content-Type", "text/plain");
        try self.resp("404 Not Found", conf);
        return err;
    };
    defer f.close();

    // Read the file into a buffer.
    const stat = try f.stat();
    const buffer = try f.readToEndAlloc(self.allocator, stat.size);
    defer self.allocator.free(buffer);

    try self.resp(buffer, conf);
}

pub fn getParam(self: *Self, key: []const u8) ?Param {
    return self.params.get(key);
}

pub fn setStatus(self: *Self, status: std.http.Status) !void {
    self.response.status = status;
}

fn resp(self: *Self, content: []const u8, conf: Config.Context) anyerror!void {
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

/// Run the next middleware or handler in the chain.
pub inline fn next(self: *Context) anyerror!void {
    self.index += 1;

    if (self.index >= self.handlers.items.len) return;

    try self.handlers.items[self.index](self);

    self.index += 1;
}

pub fn redirect(self: *Self, http_status: std.http.Status, url: []const u8) anyerror!void {
    try self.headers.add("Location", url);
    try self.request.server_request.respond("", .{ .status = http_status, .reason = http_status.phrase(), .extra_headers = self.headers.items(), .keep_alive = false });
}

pub const queryError = error{
    Empty,
    NotFound,
    InvalidValue,
    MultipleValues,
    AccessDenied,
};

/// Get the query value by name.
/// query values is an array of strings.
/// e.g /post?name=foo => queryString("name") => "foo"
/// e.g /post?name=foo&name=bar => queryString("name") => queryError.MultipleValues
/// e.g /post?name=foo&name=bar => queryString("any") => queryError.Empty
pub fn queryString(self: *Self, name: []const u8) anyerror![]const u8 {
    const values = try self.queryValues(name);
    if (values.items.len > 1) {
        return queryError.MultipleValues;
    }
    return values.items[0];
}

/// Get the query value by name.
/// e.g /post?name=foo => queryValues("name") => ["foo"]
/// e.g /post?name=foo&name=bar => queryValues("name") => ["foo", "bar"]
/// e.g /post?name=foo&name=bar => queryValues("any") => queryError.Empty
pub fn queryValues(self: *Self, name: []const u8) anyerror!std.ArrayList([]const u8) {
    const query_map = self.getQueryMap() orelse return queryError.InvalidValue;
    const values: std.ArrayList([]const u8) = query_map.get(name) orelse return queryError.NotFound;

    if (values.items.len == 0) {
        return queryError.Empty;
    }

    return values;
}

/// e.g /query?ids[a]=1234&ids[b]=hello&ids[b]=world
/// queryMap("ids") => {"a": ["1234"], "b": ["hello", "world"]}
pub fn queryMap(self: *Self, map_key: []const u8) ?std.StringHashMap(std.ArrayList([]const u8)) {
    var qm: std.StringHashMap(std.ArrayList([]const u8)) = self.getQueryMap() orelse return null;
    var qit = qm.iterator();
    var inner_map: std.StringHashMap(std.ArrayList([]const u8)) = std.StringHashMap(std.ArrayList([]const u8)).init(self.allocator);

    while (qit.next()) |kv| {
        const key = kv.key_ptr.*;
        const trimmed_key = std.mem.trim(u8, key, "");
        var splited_key = std.mem.splitSequence(u8, trimmed_key, "[");
        if (splited_key.index == null) continue;
        const key_name = splited_key.first();

        if (!std.mem.eql(u8, key_name, map_key)) continue;

        const key_rest = splited_key.next();
        if (key_rest == null) continue;
        var inner_key = std.mem.splitSequence(u8, key_rest.?, "]");
        if (inner_key.index == null) continue;
        inner_map.put(inner_key.first(), kv.value_ptr.*) catch continue;
    }
    if (inner_map.capacity() == 0) {
        return null;
    }
    return inner_map;
}

test "context query" {
    var req = Request.init(.{
        .target = "/query?id=1234&message=hello&message=world&ids[a]=1234&ids[b]=hello&ids[b]=world",
    });

    var ctx = Context.init(.{ .request = &req }).?;

    var qm = ctx.getQueryMap() orelse {
        return try std.testing.expect(false);
    };

    try std.testing.expectEqualStrings(qm.get("id").?.items[0], "1234");
    try std.testing.expectEqualStrings(qm.get("message").?.items[0], "hello");
    try std.testing.expectEqualStrings(qm.get("message").?.items[1], "world");

    const idv = ctx.queryValues("id") catch return try std.testing.expect(false);
    try std.testing.expectEqualStrings(idv.items[0], "1234");

    const messages = ctx.queryArray("message") catch return try std.testing.expect(false);
    try std.testing.expectEqualStrings(messages[0], "hello");
    try std.testing.expectEqualStrings(messages[1], "world");

    const ids: std.StringHashMap(std.ArrayList([]const u8)) = ctx.queryMap("ids") orelse return try std.testing.expect(false);
    try std.testing.expectEqualStrings(ids.get("a").?.items[0], "1234");
    try std.testing.expectEqualStrings(ids.get("b").?.items[0], "hello");
    try std.testing.expectEqualStrings(ids.get("b").?.items[1], "world");
}

test "context query map" {
    var req = Request.init(.{
        .target = "/query?ids[a]=1234&ids[b]=hello&ids[b]=world",
    });

    var ctx = Context.init(.{ .request = &req }).?;

    var ids: std.StringHashMap(std.ArrayList([]const u8)) = ctx.queryMap("ids") orelse return try std.testing.expect(false);
    try std.testing.expectEqualStrings(ids.get("a").?.items[0], "1234");
    try std.testing.expectEqualStrings(ids.get("b").?.items[0], "hello");
    try std.testing.expectEqualStrings(ids.get("b").?.items[1], "world");
}

/// Get the query values as a map.
/// e.g /post?name=foo&name=bar => getQueryMap() => {"name": ["foo", "bar"]}
pub fn getQueryMap(self: *Self) ?std.StringHashMap(std.ArrayList([]const u8)) {
    if (self.query_map != null) {
        return self.query_map;
    }
    var url = URL.init(.{});
    _ = url.parseUrl(self.request.target) catch return null;
    self.query_map = url.values orelse return null;
    return self.query_map;
}

pub fn queryArray(self: *Self, name: []const u8) anyerror![][]const u8 {
    const query_map = self.getQueryMap() orelse return queryError.InvalidValue;
    const values: std.ArrayList([]const u8) = query_map.get(name) orelse return queryError.NotFound;
    if (values.items.len == 0) {
        return error.Empty;
    }
    return values.items;
}

pub fn getPostFormMap(self: *Self) ?std.StringHashMap([]const u8) {
    const req = self.request.server_request;

    const content_type = req.head.content_type orelse return null;
    _ = std.mem.indexOf(u8, content_type, "application/x-www-form-urlencoded") orelse return null;

    const content_length = req.head.content_length orelse return null;

    const request_reader = req.reader() catch return null;

    const body_buffer = request_reader.readAllAlloc(self.allocator, content_length) catch return null;

    var form = std.StringHashMap([]const u8).init(self.allocator);
    var form_data = std.mem.splitSequence(u8, body_buffer, "&");
    while (form_data.next()) |data| {
        var kv = std.mem.splitSequence(u8, data, "=");
        if (kv.buffer.len <= 2) continue;
        const key = kv.first();
        const value = kv.next().?;
        form.put(key, value) catch continue;
    }
    return form;
}

/// Get the post form values as a map.
/// e.g name[first]=foo&name[last]=bar
/// postFormMap("name") => {"first": ["foo"], "last": ["bar"]}
pub fn postFormMap(self: *Self, map_key: []const u8) ?std.StringHashMap([]const u8) {
    var qm: std.StringHashMap([]const u8) = self.getPostFormMap() orelse return null;
    var qit = qm.iterator();
    var inner_map: std.StringHashMap([]const u8) = std.StringHashMap([]const u8).init(self.allocator);

    while (qit.next()) |kv| {
        // const decoded_key = self.allocator.alloc(u8, key.len) catch continue;
        const trimmed_key = std.mem.trim(u8, std.Uri.percentDecodeInPlace(@constCast(kv.key_ptr.*)), "");
        var splited_key = std.mem.splitSequence(u8, trimmed_key, "[");
        if (splited_key.index == null) continue;
        const key_name = splited_key.first();
        // std.debug.print("key_name: {s}\n", .{key_name});

        if (!std.mem.eql(u8, key_name, map_key)) continue;

        const key_rest = splited_key.next();
        if (key_rest == null) continue;
        var inner_key = std.mem.splitSequence(u8, key_rest.?, "]");
        if (inner_key.index == null) continue;

        inner_map.put(inner_key.first(), std.Uri.percentDecodeInPlace(@constCast(kv.value_ptr.*))) catch continue;
    }
    if (inner_map.capacity() == 0) {
        return null;
    }
    return inner_map;
}

pub fn handle(self: *Self) anyerror!void {
    for (self.handlers.items) |handler| {
        if (self.index >= self.handlers.items.len) {
            continue;
        }
        try handler(self);
    }
}
