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
pub const HandlerFn = @import("zinc/handler.zig").HandlerFn;
pub const Middleware = @import("zinc/middleware.zig");
pub const RouterGroup = @import("zinc/routergroup.zig");
pub const RouteTree = @import("zinc/routetree.zig").RouteTree;
pub const RootTree = @import("zinc/routetree.zig").RootTree;

// init a single thread engine.
pub fn init(comptime conf: Config.Engine) anyerror!*Engine {
    return Engine.init(conf);
}

// create a default single thread engine.
pub fn default() anyerror!*Engine {
    return Engine.default();
}

// // Create a multithreaded server engine.
// pub fn create(comptime conf: Config.Engine) anyerror!*Engine {
//     return Engine.create(conf);
// }
