const std = @import("std");
const zinc = @import("../zinc.zig");
const Context = zinc.Context;
const HandlerFn = zinc.HandlerFn;

pub const Middleware = @This();
const Self = @This();

pub fn cors() HandlerFn {
    const H = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.response.setHeader("Access-Control-Allow-Origin", ctx.request.getHeader("Origin") orelse "*");

            if (ctx.request.method == .OPTIONS) {
                try ctx.response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
                try ctx.response.setHeader("Access-Control-Allow-Headers", "Content-Type");
                try ctx.response.setHeader("Access-Control-Allow-Private-Network", "true");
                ctx.response.setStatus(.no_content);
                return;
            }

            try ctx.next();
        }
    };
    return H.handle;
}
