const std = @import("std");
const http = std.http;
const Method = http.Method;

const Handler = @import("handler.zig");
const HandlerFn = Handler.HandlerFn;
const HandlerChain = Handler.Chain;

pub const Middleware = @This();
const Self = @This();

methods: []const Method = &[_]Method{
    .GET,
    .POST,
    .PUT,
    .DELETE,
    .PATCH,
    .OPTIONS,
},

handlers: std.ArrayList(Handler.Chain) = std.ArrayList(Handler.Chain).init(std.heap.page_allocator),

prefix: []const u8 = "/",

pub fn init(self: Self) Middleware {
    return .{
        .methods = self.methods,
        .prefix = self.prefix,
        .handlers = self.handlers,
    };
}

pub fn add(self: *Self, methods: []const std.http.Method, handler: Handler.HandlerFn) anyerror!void {
    if (methods.len == 0) {
        try self.use(handler);
    }
}

pub fn addHandler(self: *Self, method: Method, handler: Handler.HandlerFn) anyerror!void {
    var index: usize = undefined;
    for (self.methods, 0..) |m, i| {
        if (m == method) {
            index = i;
        }
    }
    try self.handlers.append(.{ .handler = handler });
}

pub fn getHandler(self: *Self, method: Method) !Handler.HandlerFn {
    const index = self.methods.index(method);
    if (index == self.methods.len) {
        return null;
    }
    return self.handlers[index];
}

pub fn handle(self: *Self, ctx: *Handler.Context, req: *Handler.Request, res: *Handler.Response) anyerror!void {
    const method = req.method;
    const handler = try self.getHandler(method);
    if (handler == null) {
        return;
    }
    return handler(ctx, req, res);
}

pub fn use(self: *Self, handler: Handler.HandlerFn) anyerror!void {
    const methods = self.methods;
    for (methods) |method| {
        try self.addHandler(method, handler);
    }
}
