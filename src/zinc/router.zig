const HandlerFn = @import("handler.zig").HandlerFn;

pub const Router = struct {
    routes: []Route,

    pub fn get(self: Router, path: []const u8) void {
         _ = self;
        _ = path;
        // self.routes.append(Route{.path = path, .handler = handler});
    }
    pub fn post(self: Router, path: []const u8) void {
         _ = self;
        _ = path;
        // self.routes.append(Route{.path = path, .handler = handler});
    }

};

pub const Route = struct {
     path: []const u8,
    //  handler: HandlerFn,
};