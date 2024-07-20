const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const Uri = std.Uri;
const Allocator = mem.Allocator;
const proto = http.protocol;

// pub const Context = @This();

pub const Context = struct {
    request: http.Server.Request,
    response: http.Server.Response,
    params: std.StringHashMap([]const u8),
    allocator: *const mem.Allocator,

    pub fn init(allocator: *const mem.Allocator, request: http.Server.Request, response: http.Server.Response) Context {
        return Context{
            .request = request,
            .response = response,
            .params = std.StringHashMap(allocator),
            .allocator = allocator,
        };
    }
};
