const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const Uri = std.Uri;
const Allocator = mem.Allocator;
const proto = http.protocol;

const Response = @import("response.zig").Response;

pub const Context = struct {
    pub fn init() Context {
        return Context{};
    }
};
