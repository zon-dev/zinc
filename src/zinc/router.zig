const std = @import("std");
const print = std.debug.print;

const HandlerFn = @import("handler.zig").HandlerFn;
// const Handler = @import("handler.zig").Handler;
const HandleAction = @import("handler.zig").HandleAction;
const Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Route = @import("route.zig");

pub const Router = @This();
const Self = @This();

// routes: std.ArrayList(Route) = std.ArrayList(Route).init(std.heap.page_allocator),
routes: std.ArrayList(Route),

pub fn init() Router {
    return Router{
        .routes = std.ArrayList(Route).init(std.heap.page_allocator),
    };
}

/// Return a copy of the routes.
pub fn getRoutes(self: *Self) std.ArrayList(Route) {
    var rs = std.ArrayList(Route).init(std.heap.page_allocator);
    for (self.routes.items) |route| {
        rs.append(route) catch |err| {
            print("error: {s}\n", .{@errorName(err)});
        };
    }
   return rs;
}

pub fn new(comptime routes : []Route) Router {
    return Router {.routes = routes};
}

pub fn addRoute(self: *Self, route: Route) anyerror!void {
    try self.routes.append(route);
}
