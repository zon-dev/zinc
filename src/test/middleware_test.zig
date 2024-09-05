const std = @import("std");
const zinc = @import("../zinc.zig");
const expect = std.testing.expect;

test "Middleware" {
    var router = zinc.Router.init(.{});

    var signature: []const u8 = undefined;
    signature = "";

    const mid1 = struct {
        fn testMiddle1(c: *zinc.Context) anyerror!void {
            signature += "A";
            try c.next();
            signature += "B";
        }
    }.testMiddle1;

    try router.use(&.{mid1});
    try std.testing.expectEqualStrings("AB", signature);
}
