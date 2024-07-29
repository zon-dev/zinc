const Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;


// HandlerFn defines the handler used by zinc middleware as return value.
pub const HandlerFn = fn (*Context, *Request, *Response) anyerror!void;

// pub const Handler = struct {
//     // handlerFn: HandlerFn,
// };

pub const Handler = struct {
    handlerFn: HandlerFn,
};

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
// pub fn HandleAction( t: type) type {
//     if (t == void) {
//         return *const fn (*Request, *Response) anyerror!void;
//     }
//     return *const fn (t, *Request, *Response) anyerror!void;
// }