//! `zinc.Request`: lazy header map, reset for the object pool.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Request = zinc.Request;
const harness = @import("harness.zig");

fn req(method: std.http.Method, target: []const u8) !*Request {
    return harness.newRequest(testing.allocator, method, target);
}

test "Request: init records method and target" {
    const r = try req(.GET, "/users");
    defer r.deinit();

    try testing.expectEqual(std.http.Method.GET, r.method);
    try testing.expectEqualStrings("/users", r.target);
    try testing.expectEqual(std.http.Status.ok, r.status);
}

test "Request: init leaves target empty when none is supplied" {
    const r = try Request.init(.{
        .allocator = testing.allocator,
        .head = harness.head(.{}),
    });
    defer r.deinit();
    try testing.expectEqualStrings("", r.target);
}

test "Request: header map is not allocated until first write" {
    const r = try req(.GET, "/");
    defer r.deinit();

    try testing.expect(!r.header_initialized);
    try testing.expect(r.header == null);
    try testing.expect(r.getHeader("Content-Type") == null);
}

test "Request: setHeader then getHeader" {
    const r = try req(.POST, "/submit");
    defer r.deinit();

    try r.setHeader("Content-Type", "application/json");
    try r.setHeader("X-Request-Id", "req-42");

    try testing.expect(r.header_initialized);
    try testing.expectEqualStrings("application/json", r.getHeader("Content-Type").?);
    try testing.expectEqualStrings("req-42", r.getHeader("X-Request-Id").?);
    try testing.expect(r.getHeader("Authorization") == null);
}

test "Request: getHeader is case-sensitive" {
    const r = try req(.GET, "/");
    defer r.deinit();
    try r.setHeader("Content-Type", "text/plain");
    try testing.expect(r.getHeader("content-type") == null);
    try testing.expect(r.getHeader("Content-Type") != null);
}

test "Request: setHeader overwrites an existing key" {
    const r = try req(.GET, "/");
    defer r.deinit();
    try r.setHeader("Accept", "text/html");
    try r.setHeader("Accept", "application/json");
    try testing.expectEqualStrings("application/json", r.getHeader("Accept").?);
    try testing.expectEqual(@as(usize, 1), r.header.?.count());
}

test "Request: setStatus updates the status" {
    const r = try req(.GET, "/");
    defer r.deinit();
    r.setStatus(.not_found);
    try testing.expectEqual(std.http.Status.not_found, r.status);
    r.setStatus(.internal_server_error);
    try testing.expectEqual(std.http.Status.internal_server_error, r.status);
}

test "Request: reset clears target, query and status; headers survive" {
    const r = try req(.POST, "/submit?a=1");
    defer r.deinit();

    r.query = .{ .raw = "a=1" };
    r.setStatus(.created);
    try r.setHeader("X-Pooled", "yes");
    r.reset();

    try testing.expectEqualStrings("", r.target);
    try testing.expect(r.query == null);
    try testing.expectEqual(std.http.Status.ok, r.status);
    try testing.expect(r.header_initialized);
    try testing.expectEqualStrings("yes", r.getHeader("X-Pooled").?);

    r.target = "/second";
    r.method = .PUT;
    try r.setHeader("X-Second", "1");
    try testing.expectEqualStrings("/second", r.target);
    try testing.expectEqual(std.http.Method.PUT, r.method);
    try testing.expectEqualStrings("1", r.getHeader("X-Second").?);
}

test "Request: every HTTP method round-trips" {
    for (harness.methods) |method| {
        const r = try req(method, "/any");
        defer r.deinit();
        try testing.expectEqual(method, r.method);
    }
}

test "Request: head carries content metadata" {
    const r = try Request.init(.{
        .allocator = testing.allocator,
        .method = .POST,
        .target = "/upload",
        .head = harness.head(.{
            .method = .POST,
            .target = "/upload",
            .content_type = "application/x-www-form-urlencoded",
            .content_length = 11,
            .keep_alive = true,
        }),
    });
    defer r.deinit();

    try testing.expectEqualStrings("application/x-www-form-urlencoded", r.head.content_type.?);
    try testing.expectEqual(@as(u64, 11), r.head.content_length.?);
    try testing.expect(r.head.keep_alive);
}

test "Request: deinit of a request that never allocated headers does not leak" {
    for (0..8) |_| {
        const r = try req(.GET, "/");
        r.deinit();
    }
}
