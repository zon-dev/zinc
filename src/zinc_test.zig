const std = @import("std");

test {
    _ = @import("test/headers_test.zig");
    _ = @import("test/route_test.zig");
    _ = @import("test/router_test.zig");
}
