const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const Uri = std.Uri;
const Allocator = mem.Allocator;
const Server = @This();
const proto = @import("protocol");

// export zinc as package
export const zinc = struct {
    pub const Version = "0.1.0";
    pub const Description = "High-performance web framework written in Zig.";
    pub const License = "MIT";
    pub const Repository = "github.com/dravenk/zinc";
    pub const Author = "dravenk";
};
