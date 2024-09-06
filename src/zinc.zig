pub const Context = @import("zinc/context.zig");
pub const Config = @import("zinc/config.zig");
pub const Catchers = @import("zinc/catchers.zig");
pub const Engine = @import("zinc/engine.zig");
pub const Param = @import("zinc/param.zig");
pub const Request = @import("zinc/request.zig");
pub const Response = @import("zinc/response.zig");
pub const Route = @import("zinc/route.zig");
pub const Router = @import("zinc/router.zig");
pub const Headers = @import("zinc/headers.zig");
pub const Handler = @import("zinc/handler.zig");
pub const HandlerFn = @import("zinc/handler.zig").HandlerFn;
pub const Middleware = @import("zinc/middleware.zig");
pub const RouterGroup = @import("zinc/routergroup.zig");
pub const RouteTree = @import("zinc/routetree.zig").RouteTree;

pub fn init(comptime conf: Config.Engine) !Engine {
    return Engine.init(conf);
}

pub fn default() !Engine {
    return Engine.default();
}
