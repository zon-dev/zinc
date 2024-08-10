const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const proto = http.protocol;
const Server = http.Server;
const Allocator = std.mem.Allocator;

const Router = @import("router.zig");
const Route = @import("route.zig");
const Context = @import("context.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");
const config = @import("config.zig");
const Middleware = @import("middleware.zig");
const Handler = @import("handler.zig");
const HandlerFn = Handler.HandlerFn;
const Catchers = @import("catchers.zig");

pub const Engine = @This();
const Self = @This();

var logger = @import("logger.zig").init(.{});

allocator: Allocator = std.heap.page_allocator,

net_server: std.net.Server,
threads: []std.Thread = &[_]std.Thread{},
mutex: std.Thread.Mutex = .{},

router: Router = Router.init(.{}),

// catchers: std.AutoHashMap(http.Status, HandlerFn) = std.AutoHashMap(http.Status, HandlerFn).init(std.heap.page_allocator),

catchers: Catchers = Catchers.init(std.heap.page_allocator),

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
                error.HttpConnectionClosing => continue :ready,
                else => |e| return e,
            };
            const method = request.head.method;
            const target = request.head.target;

            var req = Request.init(.{ .request = &request });
            var res = Response.init(.{ .request = &request });
            var ctx = Context.init(.{ .request = &req, .response = &res });
            const match_route = self.router.matchRoute(method, target) catch |err| {
                switch (err) {
                    Route.RouteError.NotFound => {
                        if (self.getCatcher(.not_found)) |notFoundHande| {
                            try notFoundHande(&ctx, &req, &res);
                            continue :accept;
                        }
                        try request.respond("404 - Not Found", .{ .status = .not_found, .keep_alive = false });
                        continue :accept;
                    },
                    Route.RouteError.MethodNotAllowed => {
                        if (self.getCatcher(.method_not_allowed)) |methodNotAllowedHande| {
                            try methodNotAllowedHande(&ctx, &req, &res);
                            continue :accept;
                        }
                        try request.respond("405 - Method Not Allowed", .{ .status = .method_not_allowed, .keep_alive = false });
                        continue :accept;
                    },
                    else => |e| return e,
                }
            };
            try match_route.handle(&ctx, &req, &res);
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

pub fn getCatchers(self: *Self) *Catchers {
    return &self.catchers;
}
pub fn getCatcher(self: *Self, status: http.Status) ?HandlerFn {
    return self.catchers.get(status);
}

/// use middleware to match any route
pub fn use(self: *Self, middleware: Middleware) anyerror!void {
    self.router.use(middleware);
}
