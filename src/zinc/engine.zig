const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const proto = http.protocol;
const Server = http.Server;
const Allocator = std.mem.Allocator;
const page_allocator = std.heap.page_allocator;

const URL = @import("url");

const zinc = @import("../zinc.zig");

const Router = zinc.Router;
const Route = zinc.Route;
const RouterGroup = zinc.RouterGroup;
const Context = zinc.Context;
const Request = zinc.Request;
const Response = zinc.Response;
const config = zinc.Config;
const Handler = zinc.Handler;
const HandlerFn = Handler.HandlerFn;
const Catchers = zinc.Catchers;

pub const Engine = @This();
const Self = @This();

allocator: Allocator = page_allocator,

net_server: std.net.Server,
threads: []std.Thread = &[_]std.Thread{},
mutex: std.Thread.Mutex = .{},

router: Router = Router.init(.{}),

// To lower memory usage and improve performance but mybe crash when request body is too large
read_buffer_len: usize = 1024,

header_buffer_len: usize = 1024,
body_buffer_len: usize = 10 * 1024,

catchers: Catchers = Catchers.init(std.heap.page_allocator),

middlewares: std.ArrayList(HandlerFn) = std.ArrayList(HandlerFn).init(std.heap.page_allocator),

pub fn getPort(self: *Self) u16 {
    return self.net_server.listen_address.getPort();
}
pub fn getAddress(self: *Self) net.Address {
    return self.net_server.listen_address;
}

pub fn init(comptime conf: config.Engine) !Engine {
    const listen_addr = conf.addr;
    const listen_port = conf.port;

    const address = try std.net.Address.parseIp(listen_addr, listen_port);
    var listener = try address.listen(.{ .reuse_address = true });
    errdefer listener.deinit();
    return Engine{
        .allocator = conf.allocator,
        .catchers = Catchers.init(conf.allocator),
        .net_server = listener,
        .threads = undefined,
        .read_buffer_len = conf.read_buffer_len,
        .header_buffer_len = conf.header_buffer_len,
        .body_buffer_len = conf.body_buffer_len,
    };
}

pub fn default() !Engine {
    // // std.Thread.spawn(.{}, run_server, .{self.net_server}) catch @panic("thread spawn");
    return init(.{
        .addr = "127.0.0.1",
        .port = 0,
    });
}

pub fn deinit(self: *Self) void {
    // std.debug.print("deinit\n", .{});
    self.router.routes.deinit();
    self.net_server.deinit();
}

pub fn run(self: *Self) !void {
    var net_server = self.net_server;
    // var read_buffer: [1024]u8 = undefined;
    var read_buffer: []u8 = undefined;
    read_buffer = try self.allocator.alloc(u8, self.read_buffer_len);
    defer self.allocator.free(read_buffer);

    accept: while (true) {
        const conn = try net_server.accept();
        defer conn.stream.close();

        var http_server = http.Server.init(conn, read_buffer);

        ready: while (http_server.state == .ready) {
            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => break :ready,
                error.HttpHeadersOversize => {
                    // std.debug.print("HttpHeadersOversize\n", .{});
                    _ = try conn.stream.write("HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Type: text/html\r\n\r\n<h1>Request Header Fields Too Large</h1>");
                    break :ready;
                },
                else => |e| return e,
            };

            const method = request.head.method;

            if (method == .HEAD) {
                return request.respond("", .{ .status = .ok, .keep_alive = false });
            }

            var req = Request.init(.{ .req = &request, .allocator = self.allocator });
            var res = Response.init(.{ .req = &request, .allocator = self.allocator });
            var ctx = Context.init(.{ .request = &req, .response = &res, .allocator = self.allocator }) orelse {
                try res500(conn.stream);
                continue :accept;
            };
            defer ctx.deinit();

            const match_route = self.router.matchRoute(method, request.head.target) catch |err| {
                switch (err) {
                    Route.RouteError.NotFound => {
                        if (self.getCatcher(.not_found)) |notFoundHande| {
                            try notFoundHande(&ctx);
                            continue :accept;
                        }
                        try res404(conn.stream);
                        continue :accept;
                    },
                    Route.RouteError.MethodNotAllowed => {
                        if (self.getCatcher(.method_not_allowed)) |methodNotAllowedHande| {
                            try methodNotAllowedHande(&ctx);
                            continue :accept;
                        }
                        try res405(conn.stream);
                        continue :accept;
                    },
                    else => |e| return e,
                }
            };

            ctx.handlers = match_route.handlers_chain;
            ctx.handle() catch try res500(conn.stream);
        }
        // closing
        // while (http_server.state == .closing) {
        //     std.debug.print("closing\n", .{});
        //     continue :accept;
        // }
    }
}

pub fn addRouter(self: *Self, r: Router) void {
    self.router = r;
}
pub fn getRouter(self: *Self) *Router {
    return &self.router;
}

pub fn getCatchers(self: *Self) *Catchers {
    return &self.catchers;
}
pub fn getCatcher(self: *Self, status: http.Status) ?HandlerFn {
    return self.catchers.get(status);
}

/// use middleware to match any route
pub fn use(self: *Self, handlers: []const HandlerFn) anyerror!void {
    try self.middlewares.appendSlice(handlers);
    try self.routeRebuild();
}

fn routeRebuild(self: *Self) anyerror!void {
    try self.router.middlewares.appendSlice(self.middlewares.items);
    try self.router.rebuild();
}

// static dir
pub fn static(self: *Self, path: []const u8, dir_name: []const u8) anyerror!void {
    try self.router.static(path, dir_name);
}

// static file
pub fn StaticFile(self: *Self, path: []const u8, file_name: []const u8) anyerror!void {
    try self.router.staticFile(path, file_name);
}

fn res405(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/html\r\n\r\n<h1>Method Not Allowed</h1>");
}

fn res404(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\n\r\n<h1>Not Found</h1>");
}

/// Response server error 500
fn res500(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n<h1>Internal Server Error</h1>");
}
