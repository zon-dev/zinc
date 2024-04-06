const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const Uri = std.Uri;
const Allocator = mem.Allocator;
const Server = @This();
const proto = @import("protocol");

pub export fn ping() *const [4:0]u8 {
    return "ping";
}
