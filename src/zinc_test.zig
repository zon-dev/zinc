const std = @import("std");
const zinc = @import("zinc.zig");

test {
    _ = @import("test/headers_test.zig");
    _ = @import("zinc/route.zig");
}
