const Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Handler = @This();
const Self = @This();

pub const HandlerFn = *const fn (*Context, *Request, *Response) anyerror!void;
handlerFn: HandlerFn,

pub fn Action(comptime G: type) type {
    if (G == void) {
        return *const fn (*Request, *Response) anyerror!void;
    }
    return *const fn (G, *Request, *Response) anyerror!void;
}

pub fn HandleAction(comptime t: type) type {
    if (t == void) {
        return *const fn (*Context, *Request, *Response) anyerror!void;
    }
    return *const fn (t, *Context, *Request, *Response) anyerror!void;
}
