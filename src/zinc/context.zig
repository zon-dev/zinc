const std = @import("std");
const URL = @import("url");
const RespondOptions = std.http.Server.Request.RespondOptions;
const Header = std.http.Header;
const Stringify = std.json.Stringify;

const zinc = @import("../zinc.zig");
const Request = zinc.Request;
const Response = zinc.Response;
const Config = zinc.Config;
const Param = zinc.Param;
const Route = zinc.Route;

const IO = zinc.AIO.IO;

pub const Context = @This();
const Self = @This();

const handlerFn = *const fn (*Context) anyerror!void;

allocator: std.mem.Allocator,

// TODO, Remove.
conn: std.net.Stream = undefined,

// TODO
io: *IO = undefined,

done: bool = false,
// server: posix.socket_t,
// client: posix.socket_t,
accepted_sock: std.posix.socket_t = IO.INVALID_SOCKET,
// send_buf: [10]u8 = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 },
// recv_buf: [5]u8 = [_]u8{ 0, 1, 0, 1, 0 },
recv_buf: []u8 = undefined,
// sent: usize = 0,
received: usize = 0,

request: *Request = undefined,
response: *Response = undefined,

query: ?std.Uri.Component = null,

params: std.StringHashMap(Param) = undefined,

query_map: ?std.StringHashMap(std.array_list.Managed([]const u8)) = null,

// Slice of optional function pointers
handlers: std.array_list.Managed(handlerFn) = undefined,

index: u8 = 0, // Adjust the type based on your specific needs

data: *anyopaque = undefined,

pub fn destroy(self: *Self) void {
    self.params.deinit();
    if (self.query_map != null) {
        self.query_map.?.deinit();
    }

    // self.io.cancelAll();

    self.response.deinit();

    self.request.deinit();

    const allocator = self.allocator;
    allocator.destroy(self);
}

pub fn init(self: Self) anyerror!*Context {
    // var io = try IO.IO.init(32, 0);
    const ctx = try self.allocator.create(Context);
    errdefer self.allocator.destroy(ctx);

    ctx.* = .{
        // .io = &io,
        .allocator = self.allocator,
        .request = self.request,
        .response = self.response,
        .params = std.StringHashMap(Param).init(self.allocator),
        .query = self.request.query,
        .query_map = self.query_map,
        .handlers = std.array_list.Managed(handlerFn).init(self.allocator),
        .index = self.index,
        .conn = self.conn,
        .recv_buf = self.recv_buf,
        .data = self.data,
    };

    return ctx;
}

pub fn html(self: *Self, content: []const u8, conf: Config.Context) anyerror!void {
    if (conf.keep_alive) {
        try self.setHeader("Connection", "keep-alive");
    }
    try self.setHeader("Content-Type", "text/html");
    try self.setBody(content);
    try self.setStatus(conf.status);
}

pub fn text(self: *Self, content: []const u8, conf: Config.Context) anyerror!void {
    if (conf.keep_alive) {
        try self.setHeader("Connection", "keep-alive");
    }
    try self.setHeader("Content-Type", "text/plain");
    try self.setBody(content);
    try self.setStatus(conf.status);
}

pub fn json(self: *Self, value: anytype, conf: Config.Context) anyerror!void {
    if (conf.keep_alive) {
        try self.setHeader("Connection", "keep-alive");
    }

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    var stringify = Stringify{
        .writer = &out.writer,
        .options = .{},
    };
    try stringify.write(value);

    try self.setHeader("Content-Type", "application/json");
    try self.setBody(out.written());
    try self.setStatus(conf.status);
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
        return error.NotFound;
    }

    var f = try std.fs.cwd().openFile(file_path, .{});
    defer f.close();

    // Read the file into a buffer.
    const stat = try f.stat();
    const buffer = try self.allocator.alloc(u8, stat.size);
    defer self.allocator.free(buffer);
    _ = try f.readAll(buffer);

    try self.setBody(buffer);

    try self.setStatus(conf.status);
}

pub fn dir(self: *Self, dir_name: []const u8, conf: Config.Context) anyerror!void {
    const target = self.request.target;

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
    defer self.allocator.free(sub_path);

    var f = std.fs.cwd().openFile(sub_path, .{}) catch |err| {
        return err;
    };
    defer f.close();

    // Read the file into a buffer.
    const stat = try f.stat();
    const buffer = try self.allocator.alloc(u8, stat.size);
    defer self.allocator.free(buffer);
    _ = try f.readAll(buffer);

    try self.setBody(buffer);
    try self.setStatus(conf.status);
}

pub fn getParam(self: *Self, key: []const u8) ?Param {
    return self.params.get(key);
}

pub fn getQuery(self: *Self, key: []const u8) ?[]const u8 {
    const values = self.queryValues(key) catch return null;
    if (values.items.len == 0) return null;
    return values.items[0];
}

pub fn setStatus(self: *Self, status_code: std.http.Status) !void {
    self.response.setStatus(status_code);
}

pub fn status(self: *Self, status_code: std.http.Status) !void {
    self.response.setStatus(status_code);
}
pub fn setHeader(self: *Self, key: []const u8, value: []const u8) anyerror!void {
    try self.response.setHeader(key, value);
}

pub fn setBody(self: *Self, body: []const u8) !void {
    try self.response.setBody(body);
}

pub fn getHeaders(self: *Self) []std.http.Header {
    return self.response.header.items;
}

/// Run the next middleware or handler in the chain.
pub fn next(self: *Context) anyerror!void {
    self.index += 1;

    if (self.index >= self.handlers.items.len) return;
    const handler = self.handlers.items[self.index];
    try handler(self);

    self.index += 1;
}

pub fn redirect(self: *Self, http_status: std.http.Status, url: []const u8) anyerror!void {
    try self.response.setHeader("Location", url);

    try self.send("", .{
        .status = http_status,
        .reason = http_status.phrase(),
        .extra_headers = self.response.getHeaders(),
        .keep_alive = self.response.isKeepAlive(),
    });
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
pub fn queryValues(self: *Self, name: []const u8) anyerror!std.array_list.Managed([]const u8) {
    const query_map = self.getQueryMap() orelse return queryError.InvalidValue;
    const values: std.array_list.Managed([]const u8) = query_map.get(name) orelse return queryError.NotFound;

    if (values.items.len == 0) {
        return queryError.Empty;
    }

    return values;
}

/// e.g /query?ids[a]=1234&ids[b]=hello&ids[b]=world
/// queryMap("ids") => {"a": ["1234"], "b": ["hello", "world"]}
pub fn queryMap(self: *Self, map_key: []const u8) ?std.StringHashMap(std.array_list.Managed([]const u8)) {
    var qm: std.StringHashMap(std.array_list.Managed([]const u8)) = self.getQueryMap() orelse return null;
    // defer qm.deinit();

    var qit = qm.iterator();
    var inner_map: std.StringHashMap(std.array_list.Managed([]const u8)) = std.StringHashMap(std.array_list.Managed([]const u8)).init(self.allocator);

    // defer inner_map.deinit();

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

/// Get the query values as a map.
/// e.g /post?name=foo&name=bar => getQueryMap() => {"name": ["foo", "bar"]}
pub fn getQueryMap(self: *Self) ?std.StringHashMap(std.array_list.Managed([]const u8)) {
    if (self.query_map != null) {
        return self.query_map;
    }
    var url = URL.init(.{ .allocator = self.allocator });
    _ = url.parseUrl(self.request.target) catch return null;

    self.query_map = url.values;
    return self.query_map;
}

pub fn queryArray(self: *Self, name: []const u8) anyerror![][]const u8 {
    const query_map = self.getQueryMap() orelse return queryError.InvalidValue;
    const values: std.array_list.Managed([]const u8) = query_map.get(name) orelse return queryError.NotFound;
    if (values.items.len == 0) {
        return error.Empty;
    }
    return values.items;
}

/// Get the post form values as a map.
pub fn getPostFormMap(self: *Self) !?std.StringHashMap([]const u8) {
    // const req = self.request.req;

    const content_type = self.request.head.content_type orelse return null;
    const content_length = self.request.head.content_length orelse return null;

    _ = std.mem.indexOf(u8, content_type, "application/x-www-form-urlencoded") orelse return null;

    var request_reader = self.conn.reader(self.recv_buf);

    const body_buffer = try self.allocator.alloc(u8, content_length);
    defer self.allocator.free(body_buffer);
    _ = try request_reader.file_reader.read(body_buffer);

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
pub fn postFormMap(self: *Self, map_key: []const u8) !?std.StringHashMap([]const u8) {
    var qm: std.StringHashMap([]const u8) = try self.getPostFormMap() orelse return null;
    var qit = qm.iterator();
    var inner_map: std.StringHashMap([]const u8) = std.StringHashMap([]const u8).init(self.allocator);

    while (qit.next()) |kv| {
        const trimmed_key = std.mem.trim(u8, std.Uri.percentDecodeInPlace(@constCast(kv.key_ptr.*)), "");
        var splited_key = std.mem.splitSequence(u8, trimmed_key, "[");
        if (splited_key.index == null) continue;
        const key_name = splited_key.first();
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

pub fn handlersProcess(self: *Self) anyerror!void {
    if (self.handlers.items.len == 0) return;

    for (self.handlers.items, 0..) |handler, index| {
        // Ignore handlers that have already been processed.
        if (index < self.index) {
            continue;
        }
        try handler(self);
    }
}

// pub fn routeHanlde(self: *Self, route: *Route) anyerror!void {
//     try self.handlers.appendSlice(route.handlers.items);
//     try self.handle();
// }

pub fn handle(self: *Self) anyerror!void {
    try self.handlersProcess();
    // Send the response after all handlers are executed.
    try self.doRequest();
}

pub fn doRequest(self: *Self) anyerror!void {
    // TODO: handle the case where the request is not fully received.
    // if (self.request.req.head_end == 0) return;
    const body = self.response.body orelse "";
    const keep_alive = self.request.head.keep_alive and self.response.isKeepAlive();
    if (keep_alive) {
        try self.setHeader("Connection", "keep-alive");
    } else {
        try self.setHeader("Connection", "close");
    }
    try self.send(body, .{
        .status = self.response.status,
        .extra_headers = self.response.getHeaders(),
        .keep_alive = keep_alive,
    });
}

pub fn getBody(self: *Self) []const u8 {
    return self.response.body orelse "";
}

pub fn getMethod(self: *Self) std.http.Method {
    return self.request.method;
}
