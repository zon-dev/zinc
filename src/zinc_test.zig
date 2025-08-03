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

    // Static files tests
    _ = @import("test/static_files_test.zig");

    // HTTP response tests
    _ = @import("test/http_response_test.zig");

    // AIO integration tests
    _ = @import("test/aio_integration_test.zig");
    _ = @import("test/aio_examples_test.zig");

    // Multithreading tests
    _ = @import("test/multithreading_test.zig");

    // AIO async I/O specific tests
    _ = @import("test/aio_async_test.zig");
}
