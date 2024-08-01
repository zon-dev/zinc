const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const Uri = std.Uri;
const Allocator = mem.Allocator;
const proto = http.protocol;
const Server = http.Server;

const Context = @import("context.zig").Context;
const Router = @import("router.zig");
const Route = @import("route.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Engine = @This();
const Self = @This();

net_server: std.net.Server,
threads: []std.Thread = &[_]std.Thread{},
mutex: std.Thread.Mutex = .{},

router: Router = Router.init(),

pub fn getPort(self: Self) u16 {
    return self.net_server.listen_address.getPort();
}

pub fn new(comptime listen_port: u16) !Engine {
    const address = try std.net.Address.parseIp("0.0.0.0", listen_port);
    var listener = try address.listen(.{ .reuse_address = true });
    errdefer listener.deinit();
    return Engine{
        .net_server = listener,
        .threads = undefined,
    };
}

pub fn default() !Engine {
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try address.listen(.{ .reuse_address = true });
    errdefer listener.deinit();
    return Engine{
        .net_server = listener,
        .threads = undefined,
    };
    // std.Thread.spawn(.{}, run_server, .{self.net_server}) catch @panic("thread spawn");
    // return self;
}

pub fn deinit(self: Self) void {
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

        while (http_server.state == .ready) {
            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => continue :accept,
                else => |e| return e,
            };

            // std.debug.print("request: {s}\n", .{request.head.target});
            for (self.router.getRoutes().items) |route| {
                if (mem.eql(u8, request.head.target, route.path)) {
                    var res = Response.init(&request);
                    var req = Request.init(&request);
                    var ctx = Context.init();
                    try route.handler(&ctx, &req, &res);
                    continue;
                }
            }

            // 404 not found
            try request.respond("", .{ .status = .not_found, .keep_alive = false });
        }
    }
}

pub fn ping(self: *Self) *const [4:0]u8 {
    _ = self;
    return "ping";
}
pub fn pong(self: *Self) *const [4:0]u8 {
    _ = self;
    return "pong";
}
pub fn addRouter(self: *Self, r: Router) void {
    self.router = r;
}
pub fn getRouter(self: *Self) Router {
    return self.router;
}
