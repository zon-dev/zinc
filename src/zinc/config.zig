const std = @import("std");
const http = std.http;
const http_version = std.http.Version;
const heap = std.heap;

const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;
const Method = http.Method;

const zinc = @import("../zinc.zig");
const HandlerFn = zinc.HandlerFn;

pub const Config = @This();

pub const Engine = struct {
    /// The server address.
    addr: []const u8 = "0.0.0.0",
    /// The server port.
    port: u16 = 0,

    /// The allocator to use.
    allocator: std.mem.Allocator = heap.page_allocator,

    /// The buffer length for the read buffer.
    read_buffer_len: usize = 10 * 1024,
    /// The buffer length for the header.
    header_buffer_len: usize = 1024,
    /// The buffer length for the body.
    body_buffer_len: usize = 8 * 1024,

    /// The stack size for each thread.
    stack_size: usize = 10 * 1024 * 1024,

    /// The number of threads to use.
    num_threads: u8 = 8,
};

pub const Context = struct {
    status: http.Status = .ok,
    // query: StringHashMap([]const u8) = StringHashMap([]const u8).init(page_allocator),
    // params: ArrayList([]const u8) = ArrayList([]const u8).init(page_allocator),
};
