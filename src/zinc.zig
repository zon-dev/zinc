pub const Engine = @import("zinc/engine.zig").Engine;
pub const Context = @import("zinc/context.zig").Context;
pub const Request = @import("zinc/request.zig").Request;
pub const Response = @import("zinc/response.zig").Response;
pub const Route = @import("zinc/route.zig").Route;
pub const Router = @import("zinc/router.zig").Router;
pub const Headers = @import("zinc/headers.zig").Headers;
pub const Config = @import("zinc/config.zig").Config;
pub const Handler = @import("zinc/handler.zig").Handler;
pub const HandlerFn = @import("zinc/handler.zig").HandlerFn;
pub const Middleware = @import("zinc/middleware.zig").Middleware;

pub fn init(comptime conf: Config.Engine) !Engine {
    return Engine.init(conf);
}

pub fn default() !Engine {
    return Engine.default();
}
