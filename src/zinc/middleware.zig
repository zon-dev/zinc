pub const Middleware = @This();
const Self = @This();

const std = @import("std");
const http = std.http;
const Method = http.Method;

const Handler = @import("handler.zig");

methods: []const Method = &[_]Method{
    .GET,
    .POST,
    .PUT,
    .DELETE,
    .PATCH,
    .OPTIONS,
},

prefix: []const u8 = "/",

handlers: []const Handler.HandlerFn = undefined,

pub fn init(self: Self) Middleware {
    return .{
        .methods = self.methods,
        .prefix = self.prefix,
        .handlers = self.handlers,
    };
}

pub fn addHandler(self: *Self, method: Method, handler: Handler.HandlerFn) void {
    const index = self.methods.index(method);
    if (index == self.methods.len) {
        return;
    }
    self.handlers[index] = handler;
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

pub fn use(self: *Self, handler: Handler.HandlerFn) void {
    const methods = self.methods;
    for (methods) |method| {
        self.addHandler(method, handler);
    }
}
