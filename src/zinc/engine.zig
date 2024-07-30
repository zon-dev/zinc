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

// should i add routes as part of the engine?
// routes: []Route = &[_]Route{},
// stopping: std.Thread.ResetEvent = .{},
// stopped: std.Thread.ResetEvent = .{},
pub fn getPort(self: Self) u16 {
    return self.net_server.listen_address.getPort();
}
pub  fn default() !Engine {
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
    // self.net_server.deinit();
}

fn run_server(self: Self) anyerror!void {

    const net_server = self.net_server;
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
            const ctx =  Context.init(std.testing.allocator, request, http_server.response);
            handleRequest(ctx,&request ) catch |err| {
                std.debug.print("handleRequest failed with '{s}'\n", .{@errorName(err)});
                return err;
            };
        }
    }
}
// pub fn handleRequest(request: *http.Server.Request) !void {
pub fn handleRequest(ctx:Context, req: Request, resp: Response) !void {
    _ = ctx;
    _ = resp;
    const body = try (try req.reader()).readAllAlloc(std.testing.allocator, 8192);
    defer std.testing.allocator.free(body);
    var send_buffer: [100]u8 = undefined;
    var response = req.respondStreaming(.{
        .send_buffer = &send_buffer,
        .content_length = switch (req.head.transfer_encoding) {
            .chunked => null,
            .none => req.head.content_length,
        },
    });
    try response.flush(); // Test an early flush to send the HTTP headers before the body.
    const w = response.writer();
    try w.writeAll("Hello, ");
    try w.writeAll("World!\n");
    try response.end();
}
pub fn run(self: Engine) !void {
    var listener = self.net_server;
    
    while (listener.accept()) |conn| {
         _ = try conn.stream.writer().write(hello());
    } else |err| {
        std.debug.print("error in accept: {}\n", .{err});
    }
}

pub fn get(uri: Uri) !void {
    _ = uri;
}
pub fn hello() []const u8 {
    const body = "Hello World!";
    const protocal = "HTTP/1.1 200 HELLO WORLD\r\n";
    const content_type = "Content-Type: text/html; charset=utf8\r\n";
    const line = "\r\n";
    const body_len = std.fmt.comptimePrint("{}", .{body.len});
    const content_length = "Content-Length: " ++ body_len ++ "\r\n";
    const result =
        protocal ++
        content_type ++
        content_length ++
        line ++
        body;
    return result;
}
pub fn ping(self: @This()) *const [4:0]u8 {
    _ = self;
    return "ping";
}
pub fn pong(self: @This()) *const [4:0]u8 {
    _ = self;
    return "pong";
}
pub fn addRouter(self: @This(), r: Router) void {
    self.router = r;
}
pub fn getRouter(self: Self) Router {
    return self.router;
}