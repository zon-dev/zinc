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
const HandlerFn = zinc.HandlerFn;
const Catchers = zinc.Catchers;

const default_response = @import("default_response.zig");

pub const Engine = @This();
const Self = @This();

allocator: Allocator = page_allocator,

net_server: std.net.Server,

threads: std.ArrayList(std.Thread) = undefined,

mutex: std.Thread.Mutex = .{},

// To lower memory usage and improve performance but mybe crash when request body is too large
read_buffer_len: usize = 1024,
header_buffer_len: usize = 1024,
body_buffer_len: usize = 10 * 1024,

router: Router = undefined,
catchers: Catchers = undefined,
middlewares: std.ArrayList(HandlerFn) = undefined,

pub fn getPort(self: *Self) u16 {
    return self.net_server.listen_address.getPort();
}

pub fn getAddress(self: *Self) net.Address {
    return self.net_server.listen_address;
}

fn createFromConfig(comptime conf: config.Engine) !*Engine {
    const listen_addr = conf.addr;
    const listen_port = conf.port;

    const address = try std.net.Address.parseIp(listen_addr, listen_port);
    var listener = try address.listen(.{ .reuse_address = true });
    errdefer listener.deinit();

    var engine_server = try conf.allocator.create(Engine);
    engine_server.net_server = listener;

    // options
    engine_server.allocator = conf.allocator;
    engine_server.catchers = Catchers.init(conf.allocator);
    engine_server.router = Router.init(.{ .allocator = conf.allocator });
    engine_server.middlewares = std.ArrayList(HandlerFn).init(conf.allocator);

    // buffer len
    engine_server.read_buffer_len = conf.read_buffer_len;
    engine_server.header_buffer_len = conf.header_buffer_len;
    engine_server.body_buffer_len = conf.body_buffer_len;

    return engine_server;
}

pub fn create(comptime conf: config.Engine) !*Engine {
    var engine_server = try createFromConfig(conf);

    var threads = std.ArrayList(std.Thread).init(engine_server.allocator);
    errdefer engine_server.allocator.free(threads.items);

    for (conf.threads) |_| {
        const thread = try std.Thread.spawn(.{
            .stack_size = conf.stack_size,
            .allocator = conf.allocator,
        }, Engine.run, .{engine_server});

        try threads.append(thread);
    }
    engine_server.threads = threads;

    return engine_server;
}

pub fn init(comptime conf: config.Engine) !Engine {
    const address = try std.net.Address.parseIp(conf.addr, conf.port);
    var listener = try address.listen(.{ .reuse_address = true });
    errdefer listener.deinit();

    var engine = Engine{
        .allocator = conf.allocator,
        .net_server = listener,
        .threads = undefined,
        .read_buffer_len = conf.read_buffer_len,
        .header_buffer_len = conf.header_buffer_len,
        .body_buffer_len = conf.body_buffer_len,
        .catchers = Catchers.init(conf.allocator),
        .router = Router.init(.{ .allocator = conf.allocator }),
        .middlewares = std.ArrayList(HandlerFn).init(conf.allocator),
    };

    var threads = std.ArrayList(std.Thread).init(engine.allocator);
    errdefer engine.allocator.free(threads.items);

    for (conf.threads) |_| {
        const thread = try std.Thread.spawn(.{
            .stack_size = conf.stack_size,
            .allocator = conf.allocator,
        }, Engine.run, .{&engine});

        try threads.append(thread);
    }
    engine.threads = threads;
    return engine;
}

pub fn getTheadCount(self: *Self) usize {
    return self.threads.items.len;
}

pub fn default() !Engine {
    return init(.{
        .addr = "127.0.0.1",
        .port = 0,
    });
}

pub fn shutdown(self: *Self) void {
    self.net_server.deinit();
}

// pub fn destroy(self: *@This()) void {
pub fn destroy(self: *Self) void {
    // if (std.net.tcpConnectToAddress(self.getAddress())) |c| c.close() else |_| {}

    // TODO
    // for (self.threads.items, 0..) |t, i| {
    //     std.debug.print("thread {d} is closing\n", .{i});
    //     t.join();
    // }
    self.allocator.free(self.threads.items);

    self.net_server.deinit();

    self.router.routes.deinit();
    self.catchers.catchers.deinit();
    self.middlewares.deinit();

    self.allocator.destroy(self);
}

pub fn run(self: *Self) anyerror!void {
    var net_server = self.net_server;
    var read_buffer: []u8 = undefined;
    read_buffer = try self.allocator.alloc(u8, self.read_buffer_len);
    defer self.allocator.free(read_buffer);

    accept: while (true) {
        const conn = net_server.accept() catch |err| switch (err) {
            error.ConnectionAborted => continue :accept,
            else => return,
        };

        defer conn.stream.close();

        var http_server = http.Server.init(conn, read_buffer);
        ready: while (http_server.state == .ready) {
            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => continue :ready,
                error.HttpHeadersOversize => return default_response.requestHeaderFieldsTooLarge(conn.stream),
                // else => |e| return e,
                else => {
                    try default_response.badRequest(conn.stream);
                    continue :accept;
                },
            };

            const method = request.head.method;

            var req = Request.init(.{ .req = &request, .allocator = self.allocator });
            var res = Response.init(.{ .req = &request, .allocator = self.allocator });
            var ctx = Context.init(.{ .request = &req, .response = &res, .allocator = self.allocator }) orelse {
                try default_response.internalServerError(conn.stream);
                continue :accept;
            };
            const match_route = self.router.getRoute(method, request.head.target) catch |err| {
                try self.catchRouteError(err, conn.stream, &ctx);
                continue :accept;
            };
            ctx.handlers = match_route.handlers_chain;
            ctx.handle() catch try default_response.internalServerError(conn.stream);

            ctx.deinit();
        }
        // closing
        while (http_server.state == .closing) {
            // std.debug.print("The connection is closing\n", .{});
            continue :accept;
        }
    }
}

fn catchRouteError(self: *Self, err: anyerror, stream: net.Stream, ctx: *Context) anyerror!void {
    switch (err) {
        Route.RouteError.NotFound => {
            if (!ctx.request.method.responseHasBody()) {
                _ = try stream.write("HTTP/1.1 404 Not Found\r\n\r\n");
                return;
            }

            if (self.getCatcher(.not_found)) |notFoundHande| {
                try notFoundHande(ctx);
                return;
            }
            try default_response.notFound(stream);
            return;
        },
        Route.RouteError.MethodNotAllowed => {
            if (self.getCatcher(.method_not_allowed)) |methodNotAllowedHande| {
                try methodNotAllowedHande(ctx);
                return;
            }
            try default_response.methodNotAllowed(stream);
            return;
        },
        else => |e| return e,
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
