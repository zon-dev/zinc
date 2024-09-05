const std = @import("std");

const zinc = @import("../zinc.zig");
const Context = zinc.Context;
const Request = zinc.Request;
const Response = zinc.Response;

pub const Handler = @This();
const Self = @This();

pub const HandlerFn = *const fn (*Context) anyerror!void;
pub const HandlersChain: std.ArrayList(HandlerFn) = std.ArrayList(HandlerFn).init(std.heap.page_allocator);
pub fn HandleAction(comptime t: type) type {
    if (t == void) {
        return *const fn (*Context) anyerror!void;
    }
    return *const fn (t, *Context) anyerror!void;
}
