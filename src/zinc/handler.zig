const Context = @import("context.zig").Context;
const Resquest = @import("request.zig").Request;
const Response = @import("response.zig").Response;


// HandlerFn defines the handler used by zinc middleware as return value.
pub const HandlerFn = fn (Context, Resquest, Response) void;

pub const Handler = struct {
    // handler: HandlerFn,
};
