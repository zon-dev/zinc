const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.net;
const proto = http.protocol;
const Server = http.Server;
const Allocator = std.mem.Allocator;

const zinc = @import("../zinc.zig");
const Handler = zinc.Handler;
const HandlerFn = Handler.HandlerFn;

pub const Self = @This();

catchers: std.AutoHashMap(http.Status, HandlerFn) = std.AutoHashMap(http.Status, HandlerFn).init(std.heap.page_allocator),

pub fn init(allocator: Allocator) Self {
    return .{
        .catchers = std.AutoHashMap(http.Status, HandlerFn).init(allocator),
    };
}

pub fn get(self: *Self, status: http.Status) ?HandlerFn {
    return self.catchers.get(status);
}

pub fn put(self: *Self, status: http.Status, handler: HandlerFn) Allocator.Error!void {
    try self.catchers.put(status, handler);
}

pub fn setNotFound(self: *Self, handler: HandlerFn) Allocator.Error!void {
    try self.catchers.put(http.Status.not_found, handler);
}
pub fn setMethodNotAllowed(self: *Self, handler: HandlerFn) Allocator.Error!void {
    try self.catchers.put(http.Status.method_not_allowed, handler);
}
pub fn setInternalServerError(self: *Self, handler: HandlerFn) Allocator.Error!void {
    try self.catchers.put(http.Status.internal_server_error, handler);
}

pub fn notFound(self: *Self) ?HandlerFn {
    return self.get(http.Status.not_found);
}
pub fn methodNotAllowed(self: *Self) ?HandlerFn {
    return self.get(http.Status.method_not_allowed);
}
pub fn internalServerError(self: *Self) ?HandlerFn {
    return self.get(http.Status.internal_server_error);
}
