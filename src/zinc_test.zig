test {
    _ = @import("test/harness.zig");

    _ = @import("test/parser_test.zig");
    _ = @import("test/headers_test.zig");
    _ = @import("test/request_test.zig");
    _ = @import("test/response_test.zig");
    _ = @import("test/context_test.zig");
    _ = @import("test/route_test.zig");
    _ = @import("test/routetree_test.zig");
    _ = @import("test/router_test.zig");
    _ = @import("test/routergroup_test.zig");
    _ = @import("test/middleware_test.zig");
    _ = @import("test/catchers_test.zig");
    _ = @import("test/static_files_test.zig");
    _ = @import("test/engine_test.zig");
    _ = @import("test/performance_test.zig");
}
