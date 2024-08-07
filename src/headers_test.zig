const std = @import("std");
const testing = std.testing;
const z = @import("zinc.zig");
const Headers = z.Headers;

test Headers {
    var headers = Headers.init();
    try headers.add("Content-Type", "text/html");
    try headers.add("Content-Length", "100");
    try testing.expect(headers.len() == 2);
    try testing.expectEqualStrings(headers.get("Content-Type").?.name, "Content-Type");
    try testing.expectEqualStrings(headers.get("Content-Type").?.value, "text/html");
    try testing.expectEqualStrings(headers.get("Content-Length").?.name, "Content-Length");

    try headers.set("Content-Length", "200");
    try testing.expectEqualStrings(headers.get("Content-Length").?.value, "200");
    try headers.remove("Content-Length");
    try testing.expect(headers.len() == 1);
    headers.clear();
    try testing.expect(headers.len() == 0);
}
