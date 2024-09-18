const std = @import("std");

test {
    _ = @import("test/context_test.zig");
    _ = @import("test/headers_test.zig");
    _ = @import("test/route_test.zig");
    _ = @import("test/router_test.zig");
    _ = @import("test/routetree_test.zig");
    _ = @import("test/routergroup_test.zig");
    _ = @import("test/engine_test.zig");
    _ = @import("test/middleware_test.zig");
}
