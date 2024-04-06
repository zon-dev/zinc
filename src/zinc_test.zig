const std = @import("std");
const testing = std.testing;
const z = @import("zinc");

test "basic ping functionality" {
    try testing.expect(std.mem.eql(u8, z.ping(), "ping"));
}
