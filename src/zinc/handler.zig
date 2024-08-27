const std = @import("std");

const Context = @import("context.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");

const allocator = std.heap.page_allocator;

pub const Handler = @This();
const Self = @This();

// handlerFn: HandlerFn,

pub const HandlerFn = *const fn (*Context) anyerror!void;

pub const HandlersChain: std.ArrayList(HandlerFn) = std.ArrayList(HandlerFn).init(allocator);

// pub const Chain = struct {
//     handler: HandlerFn = undefined,
//     next: *Chain = undefined,
// };
// pub const Chain: std.ArrayList(HandlerFn) = std.ArrayList(HandlerFn).init(allocator);
// pub fn link(self: *HandlersChain, handler: HandlerFn) *Chain {
//     const lasHandler = self.last();
//     const chain = Chain{
//         .handler = handler,
//         .next = null,
//     };
//     if (lasHandler != null) {
//         lasHandler.next = &chain;
//     }
//     self.append(handler);
//     return &chain;
// }

pub fn HandleAction(comptime t: type) type {
    if (t == void) {
        return *const fn (*Context) anyerror!void;
    }
    return *const fn (t, *Context) anyerror!void;
}
