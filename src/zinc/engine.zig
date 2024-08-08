const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const proto = http.protocol;
const Server = http.Server;
const Allocator = std.mem.Allocator;

const Context = @import("context.zig").Context;
const Router = @import("router.zig");
const Route = @import("route.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const HandlerFn = @import("handler.zig").HandlerFn;
const Handler = @import("handler.zig").Handler;
const config = @import("config.zig").Config;

pub const Engine = @This();
const Self = @This();

allocator: Allocator = std.heap.page_allocator,

net_server: std.net.Server,
threads: []std.Thread = &[_]std.Thread{},
mutex: std.Thread.Mutex = .{},

router: Router = Router.init(),

catchers: std.AutoHashMap(http.Status, HandlerFn) = std.AutoHashMap(http.Status, HandlerFn).init(std.heap.page_allocator),

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
        .catchers = std.AutoHashMap(http.Status, HandlerFn).init(conf.allocator),
        .net_server = listener,
        .threads = undefined,
    };
}

pub fn default() !Engine {
    // // std.Thread.spawn(.{}, run_server, .{self.net_server}) catch @panic("thread spawn");
    return init(.{ .addr = "127.0.0.1", .port = 0, });
}

pub fn deinit(self: *Self) void {
    std.debug.print("deinit\n", .{});
    self.router.routes.deinit();
    self.net_server.deinit();
}

pub fn run(self: *Self) !void {
    var net_server = self.net_server;
    var read_buffer: [1024]u8 = undefined;

    accept: while (true) {
        const conn = try net_server.accept();
        defer conn.stream.close();

        var http_server = http.Server.init(conn, &read_buffer);

        ready: while (http_server.state == .ready) {
            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => continue :accept,
                else => |e| return e,
            };

            var req = Request.init(.{ .request = &request });
            var res = Response.init(.{ .request = &request });
            var ctx = Context.init(.{ .request = &req, .response = &res });

            if (self.router.matchRoute(request.head.method, request.head.target)) |route| {
                try route.handler(&ctx, &req, &res);
                continue :ready;
            } else {
                // 404 not found!
                if (self.getCatchers().get(.not_found)) |notFoundHande| {
                    try notFoundHande(&ctx, &req, &res);
                }
            }

            try request.respond("404 - Not Found", .{ .status = .not_found, .keep_alive = false });
        }

        // closing
        while (http_server.state == .closing) {
            // std.debug.print("closing\n", .{});
            continue :accept;
        }
    }
}

pub fn addRouter(self: *Self, r: Router) void {
    self.router = r;
}
pub fn getRouter(self: *Self) *Router {
    return &self.router;
}

pub fn getCatchers(self: *Self) *std.AutoHashMap(http.Status, HandlerFn) {
    return &self.catchers;
}

pub fn getCatcher(self: *Self, status: http.Status) HandlerFn {
    return &self.catchers.get(status).?;
}

/// use middleware to match any route
pub fn use(self: *Self, comptime args: config.Middleware) anyerror!void {
    _ = self;
    _ = args;
}
