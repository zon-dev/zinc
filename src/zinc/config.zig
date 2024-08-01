const std = @import("std");
const http = std.http;
const http_version = std.http.Version;

pub const Config = @This();

allocator: std.mem.Allocator,

pub const Context = struct {
    status: http.Status = .ok,
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
