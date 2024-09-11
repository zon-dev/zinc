const std = @import("std");
const http = std.http;
const http_version = std.http.Version;
const heap = std.heap;
const page_allocator = heap.page_allocator;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;
const Method = http.Method;

const zinc = @import("../zinc.zig");
const HandlerFn = zinc.HandlerFn;

pub const Config = @This();

allocator: Allocator = page_allocator,

pub const Context = struct {
    status: http.Status = .ok,
    // query: StringHashMap([]const u8) = StringHashMap([]const u8).init(page_allocator),
    // params: ArrayList([]const u8) = ArrayList([]const u8).init(page_allocator),
};

pub const Catcher = struct {};

pub const Middleware = struct {
    methods: []const Method = &[_]Method{
        .GET,
        .POST,
        .PUT,
        .DELETE,
        .PATCH,
        .OPTIONS,
    },
    prefix: []const u8 = "/",
    handler_fn: *const fn () HandlerFn = undefined,
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

    allocator: Allocator = page_allocator,

    read_buffer_len: usize = 10 * 1024,
    header_buffer_len: usize = 1024,
    body_buffer_len: usize = 8 * 1024,

    // 1GB stack size for the every server thread.
    stack_size: usize = 2 << 29,

    // theads count
    threads: u8 = 8,
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
