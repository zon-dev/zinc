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

// threads
threads: std.ArrayList(std.Thread) = undefined,
stopping: std.Thread.ResetEvent = .{},
stopped: std.Thread.ResetEvent = .{},
mutex: std.Thread.Mutex = .{},

// buffer len
read_buffer_len: usize = undefined,
header_buffer_len: usize = undefined,
body_buffer_len: usize = undefined,

// options
router: Router = undefined,
catchers: Catchers = undefined,
middlewares: std.ArrayList(HandlerFn) = undefined,

/// Create a new engine.
fn create(comptime conf: config.Engine) !*Engine {
    const engine = try conf.allocator.create(Engine);
    errdefer conf.allocator.destroy(engine);

    const address = try std.net.Address.parseIp(conf.addr, conf.port);
    var listener = try address.listen(.{ .reuse_address = true });
    errdefer listener.deinit();

    engine.* = .{
        .allocator = conf.allocator,
        .net_server = listener,

        // buffer len
        .read_buffer_len = conf.read_buffer_len,
        .header_buffer_len = conf.header_buffer_len,
        .body_buffer_len = conf.body_buffer_len,

        // options
        .catchers = Catchers.init(conf.allocator),
        .router = Router.init(.{ .allocator = conf.allocator }),
        .middlewares = std.ArrayList(HandlerFn).init(conf.allocator),
    };

    return engine;
}

/// Initialize the engine.
pub fn init(comptime conf: config.Engine) anyerror!*Engine {
    var engine = try create(conf);
    errdefer conf.allocator.destroy(engine);
    if (conf.threads_len == 0) return engine;

    var threads = std.ArrayList(std.Thread).init(conf.allocator);
    errdefer conf.allocator.free(threads.items);
    for (conf.threads_len) |_| {
        const thread = try std.Thread.spawn(.{
            .stack_size = conf.stack_size,
            .allocator = conf.allocator,
        }, Engine.worker, .{engine});

        try threads.append(thread);
    }

    engine.threads = threads;

    return engine;
}

/// Accept a new connection.
fn accept(self: *Engine) ?std.net.Server.Connection {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.stopping.isSet()) return null;

    const conn = self.net_server.accept() catch |e| {
        if (self.stopping.isSet()) return null;
        switch (e) {
            error.ConnectionAborted => {
                // try again
                return self.accept();
            },
            else => return null,
        }
    };

    // const timeout = std.posix.timeval{
    //     .sec = @as(i32, 10),
    //     .usec = @as(i32, 0),
    // };
    // std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    return conn;
}

/// Run the server. This function will block the current thread.
pub fn run(self: *Engine) !void {
    defer self.destroy();
    self.wait();
}

/// Allocate server worker threads
fn worker(self: *Engine) anyerror!void {
    const engine_allocator = self.allocator;
    var router = self.router;
    const catchers = self.catchers;
    var read_buffer: []u8 = undefined;

    const read_buffer_len = self.read_buffer_len;
    read_buffer = try engine_allocator.alloc(u8, read_buffer_len);
    defer engine_allocator.free(read_buffer);

    accept: while (self.accept()) |conn| {
        var http_server = http.Server.init(conn, read_buffer);

        ready: while (http_server.state == .ready) {
            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => continue :ready,
                error.HttpHeadersOversize => return default_response.requestHeaderFieldsTooLarge(conn.stream),
                else => {
                    try default_response.badRequest(conn.stream);
                    continue :accept;
                },
            };

            var req = Request.init(.{ .req = &request, .allocator = engine_allocator });
            var res = Response.init(.{ .req = &request, .allocator = engine_allocator });
            var ctx = Context.init(.{ .request = &req, .response = &res, .server_request = &request, .allocator = engine_allocator }).?;

            const match_route = router.getRoute(request.head.method, request.head.target) catch |err| {
                try catchRouteError(@constCast(&catchers), err, conn.stream, &ctx);
                continue :accept;
            };
            // TODO ??
            // match_route.handle(&ctx) catch try default_response.internalServerError(conn.stream);

            ctx.handlers = match_route.handlers;
            ctx.handle() catch try default_response.internalServerError(conn.stream);
        }

        // closing
        while (http_server.state == .closing) {
            continue :accept;
        }
    }
}

fn catchRouteError(self: *Catchers, err: anyerror, stream: net.Stream, ctx: *Context) anyerror!void {
    switch (err) {
        Route.RouteError.NotFound => {
            if (!ctx.request.method.responseHasBody()) {
                _ = try stream.write("HTTP/1.1 404 Not Found\r\n\r\n");
                return;
            }

            if (self.get(.not_found)) |notFoundHande| {
                try notFoundHande(ctx);
                return;
            }
            try default_response.notFound(stream);
            return;
        },
        Route.RouteError.MethodNotAllowed => {
            if (self.get(.method_not_allowed)) |methodNotAllowedHande| {
                try methodNotAllowedHande(ctx);
                return;
            }
            try default_response.methodNotAllowed(stream);
            return;
        },
        else => |e| return e,
    }
}

pub fn destroy(self: *Self) void {
    self.stopping.set();

    if (std.net.tcpConnectToAddress(self.net_server.listen_address)) |c| c.close() else |_| {}
    self.net_server.deinit();

    for (self.threads.items, 1..) |t, i| {
        t.join();
        std.debug.print("\nthread {d} is closed", .{i});
    }

    // TODO
    // self.allocator.free(self.threads.items);
    // self.router.deinit();
    // self.catchers.catchers.deinit();
    // self.middlewares.deinit();

    self.stopped.set();
    self.allocator.destroy(self);
    std.debug.print("\nengine is stopped", .{});
}

// create a default engine
pub fn default() anyerror!*Engine {
    return init(.{
        .addr = "127.0.0.1",
        .port = 0,
    });
}

pub fn getPort(self: *Self) u16 {
    return self.net_server.listen_address.getPort();
}

pub fn getAddress(self: *Self) net.Address {
    return self.net_server.listen_address;
}

/// Wait for the server to stop.
pub fn wait(self: *Self) void {
    self.stopped.wait();
}

/// Shutdown the server.
pub fn shutdown(self: *Self) void {
    self.stopping.set();
}

/// Add custom router to engine.s
pub fn addRouter(self: *Self, r: Router) void {
    self.router = r;
}

/// Get the router.
pub fn getRouter(self: *Self) *Router {
    return &self.router;
}

/// Get the catchers.
pub fn getCatchers(self: *Self) *Catchers {
    return &self.catchers;
}

/// Get the catcher by status.
fn getCatcher(self: *Self, status: http.Status) ?HandlerFn {
    return self.catchers.get(status);
}

/// use middleware to match any route
pub fn use(self: *Self, handlers: []const HandlerFn) anyerror!void {
    try self.middlewares.appendSlice(handlers);
    try self.router.use(handlers);
}

fn routeRebuild(self: *Self) anyerror!void {
    self.router.use(self.middlewares.items);
}

// Serve a static file.
pub fn StaticFile(self: *Self, path: []const u8, file_name: []const u8) anyerror!void {
    try self.router.staticFile(path, file_name);
}

/// Serve a static directory.
pub fn static(self: *Self, path: []const u8, dir_name: []const u8) anyerror!void {
    try self.router.static(path, dir_name);
}

/// Engine error.
pub const EngineError = error{
    None,
    Stopping,
    Stopped,
};
