const std = @import("std");
const zinc = @import("../zinc.zig");
const Context = zinc.Context;
const HandlerFn = zinc.HandlerFn;

pub const Middleware = @This();
const Self = @This();

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

// pub const cors = struct {
//     // "Access-Control-Allow-Origin"
//     const Origin: []const u8 = "*";
//     // "Access-Control-Allow-Methods"
//     const Methods: []std.http.Method = &[_]std.http.Method{ .GET, .POST, .PUT, .DELETE, .OPTIONS };
//     // "Access-Control-Allow-Headers"
//     const Headers: []const u8 = "Content-Type";
//     // "Access-Control-Allow-Private-Network"
//     const Private: bool = true;
//     // "Access-Control-Max-Age"
//     const MaxAge: usize = 3600;
//     pub fn init(self: cors) cors {
//         return .{
//             .Origin = self.Origin,
//             .Methods = self.Methods,
//             .Headers = self.Headers,
//             .Private = self.Private,
//             .MaxAge = self.MaxAge,
//         };
//     }
// };
