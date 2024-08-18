const std = @import("std");
const zinc = @import("zinc.zig");

test {
    _ = @import("test/headers_test.zig");
    _ = @import("test/route_test.zig");
    _ = @import("test/router_test.zig");
}
