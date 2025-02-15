const std = @import("std");

pub const Config = @This();

pub const Engine = struct {
    /// The server address. Default is "0.0.0.0" which means all interfaces.
    addr: []const u8 = "0.0.0.0",
    /// The server port. Default is 0. This means the server will choose a random port.
    port: u16 = 0,

    /// The allocator to use.
    /// Default is the std.heap.page_allocator.
    allocator: std.mem.Allocator = std.heap.page_allocator,

    /// The buffer length for the read buffer. Default is 10KB.
    read_buffer_len: usize = 10 * 1024,
    /// The buffer length for the header. Default is 1KB.
    header_buffer_len: usize = 1024,
    /// The buffer length for the body. Default is 8KB.
    body_buffer_len: usize = 8 * 1024,

    /// The stack_size in bytes is the stack of each thread.
    /// Default is 10MB.
    /// This is only used when the `.num_threads` is greater than 1.
    stack_size: usize = 10 * 1024 * 1024,

    /// The number of threads to use. Maximum is 255.
    num_threads: u8 = 8,
    /// Data of any arbitrary type that will be passed down to each Context
    data: *anyopaque = undefined,

    pub fn appData(self: *Engine, data: anytype) void {
        self.data = data;
    }
};

pub const Context = struct {
    status: std.http.Status = std.http.Status.ok,
    keep_alive: bool = false,
};
