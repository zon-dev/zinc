const std = @import("std");
const http = std.http;
const http_version = std.http.Version;

const Handler = @import("handler.zig").Handler;

pub const Config = @This();

allocator: std.mem.Allocator,

pub const Context = struct {
    status: http.Status = .ok,
    query: std.StringHashMap([]const u8) = std.StringHashMap([]const u8).init(std.heap.page_allocator),
    params: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(std.heap.page_allocator),
};

pub const Catcher = struct {};

pub const Middleware = struct {
    methods: []const http.Method = &[_]http.Method{
        http.Method.GET,
        http.Method.POST,
        http.Method.PUT,
        http.Method.DELETE,
        http.Method.PATCH,
        http.Method.OPTIONS,
    },
    prefix: []const u8 = "/",
    handler_fn: *const fn () Handler.HandlerFn = undefined,
};

pub const CORS = struct {
    // The allowed origins.
    origins: []const u8 = "*",
    // The allowed methods.
    methods: []const u8 = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
    // The allowed headers.
    headers: []const u8 = "Content-Type, Authorization",
    // The exposed headers.
    exposed_headers: []const u8 = "Content-Type, Authorization",
    // The allowed credentials.
    credentials: bool = true,
    // The max age.
    max_age: u32 = 86400,
};

pub const Engine = struct {
    // The server address.
    addr: []const u8 = "0.0.0.0",
    // The server port.
    port: u16 = 8080,

    allocator: std.mem.Allocator = std.heap.page_allocator,
};

/// HTTP server configuration.
pub const HttpConfig = struct {
    port: usize,
    // upgrade: ?HttpUpgrade = null,

    // public folder.
    public: ?[]const u8 = null,

    // The maximum number of clients that can connect to the server.
    max_clients: ?isize = null,

    // The maximum body size.
    max_body_size: ?usize = null,

    // The server connection timeout.
    timeout: ?u8 = null,

    // The server keep-alive timeout.
    keep_alive_timeout: ?u8 = null,

    // The server read timeout.
    read_timeout: ?u8 = null,

    // log: bool = false,

    // The server TLS configuration.
    // tls: ?tls = null,
};
