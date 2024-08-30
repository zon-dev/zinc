const std = @import("std");
const http = std.http;
const Method = http.Method;

const Handler = @import("handler.zig");
const HandlerFn = Handler.HandlerFn;
const HandlerChain = Handler.Chain;

const Context = @import("context.zig");

pub const Middleware = @This();
const Self = @This();

methods: []const Method = &[_]Method{
    .GET,
    .POST,
    .PUT,
    .DELETE,
    .OPTIONS,
    .HEAD,
    .PATCH,
    .CONNECT,
    .TRACE,
},

handlers: std.ArrayList(HandlerFn) = std.ArrayList(HandlerFn).init(std.heap.page_allocator),

prefix: []const u8 = "/",

pub fn init(self: Self) Middleware {
    return .{
        .methods = self.methods,
        .prefix = self.prefix,
        .handlers = self.handlers,
    };
}

pub fn add(self: *Self, method: std.http.Method, handler: HandlerFn) anyerror!void {
    try self.addHandler(method, handler);
}

pub fn any(self: *Self, methods: []const std.http.Method, handler: HandlerFn) anyerror!void {
    if (methods.len == 0) {
        try self.use(handler);
    }
    for (methods) |method| {
        try self.addHandler(method, handler);
    }
}

pub fn addHandler(self: *Self, method: Method, handler: HandlerFn) anyerror!void {
    var index: usize = undefined;
    for (self.methods, 0..) |m, i| {
        if (m == method) {
            index = i;
        }
    }
    try self.handlers.append(handler);
}

pub fn getHandler(self: *Self, method: Method) !HandlerFn {
    const index = self.methods.index(method);
    if (index == self.methods.len) {
        return null;
    }
    return self.handlers[index];
}

pub fn handle(self: *Self, ctx: *Context) anyerror!void {
    const method = ctx.request.method();
    const handler = try self.getHandler(method);
    if (handler == null) {
        return;
    }
    return handler(ctx);
}

pub fn use(self: *Self, handler: HandlerFn) anyerror!void {
    const methods = self.methods;
    for (methods) |method| {
        try self.addHandler(method, handler);
    }
}

pub fn cors() HandlerFn {
    const H = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.request.setHeader("Access-Control-Allow-Origin", ctx.request.getHeader("Origin") orelse "*");

            if (ctx.request.method == .OPTIONS) {
                try ctx.request.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
                try ctx.request.setHeader("Access-Control-Allow-Headers", "Content-Type");
                try ctx.request.setHeader("Access-Control-Allow-Private-Network", "true");

                try ctx.response.sendStatus(.no_content);
                return;
            }

            return ctx.next();
        }
    };
    return H.handle;
}
