const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const Uri = std.Uri;
const Allocator = mem.Allocator;
const Server = @This();
const proto = @import("protocol");
const testing = std.testing;

export fn ping() *const [4:0]u8 {
    std.debug.print("{s}", .{"ping"});
    return "ping";
}

test "basic ping functionality" {
    try testing.expect(std.mem.eql(ping(), "ping"));
}
