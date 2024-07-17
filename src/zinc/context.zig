const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const Uri = std.Uri;
const Allocator = mem.Allocator;
const proto = http.protocol;

export const Context = @This();

request: http.Server.Request,
response: http.Server.Response,
params: std.StringHashMap([]const u8),
allocator: *std.mem.Allocator,

pub fn init(allocator: *std.mem.Allocator, request: http.Server.Request, response: http.Server.Response) Context {
    return Context{
        .request = request,
        .response = response,
        .params = std.StringHashMap(allocator),
        .allocator = allocator,
    };
}
