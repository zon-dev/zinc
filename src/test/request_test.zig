//! Tests for `zinc.Request`.
//!
//! `Request` lazily initializes its header map, so the interesting cases are
//! around reading headers before any write has happened, and `reset` (used by
//! the object pool) leaving the instance reusable.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Request = zinc.Request;
const harness = @import("harness.zig");

fn newRequest(method: std.http.Method, target: []const u8) !*Request {
    return Request.init(.{
        .allocator = testing.allocator,
        .method = method,
        .target = target,
        .head = harness.head(.{ .method = method, .target = target }),
    });
}

test "Request: init records method and target" {
    const req = try newRequest(.GET, "/users");
    defer req.deinit();

    try testing.expectEqual(std.http.Method.GET, req.method);
    try testing.expectEqualStrings("/users", req.target);
    try testing.expectEqual(std.http.Status.ok, req.status);
}

test "Request: init leaves target empty when none is supplied" {
    // The framework only assigns target/method when `target.len > 0`.
    const req = try Request.init(.{
        .allocator = testing.allocator,
        .head = harness.head(.{}),
    });
    defer req.deinit();

    try testing.expectEqualStrings("", req.target);
}

test "Request: header map is not allocated until first write" {
    const req = try newRequest(.GET, "/");
    defer req.deinit();

    try testing.expect(!req.header_initialized);
    try testing.expect(req.header == null);
}

test "Request: getHeader returns null before any header is set" {
    const req = try newRequest(.GET, "/");
    defer req.deinit();

    // Must not touch the uninitialized map.
    try testing.expect(req.getHeader("Content-Type") == null);
}

test "Request: setHeader then getHeader" {
    const req = try newRequest(.POST, "/submit");
    defer req.deinit();

    try req.setHeader("Content-Type", "application/json");
    try req.setHeader("X-Request-Id", "req-42");

    try testing.expect(req.header_initialized);
    try testing.expectEqualStrings("application/json", req.getHeader("Content-Type").?);
    try testing.expectEqualStrings("req-42", req.getHeader("X-Request-Id").?);
}

test "Request: getHeader is case-sensitive" {
    const req = try newRequest(.GET, "/");
    defer req.deinit();

    try req.setHeader("Content-Type", "text/plain");

    // Unlike `Headers.get`, the request map is a plain StringArrayHashMap.
    // Pinning this asymmetry so it is a deliberate choice, not a surprise.
    try testing.expect(req.getHeader("content-type") == null);
    try testing.expect(req.getHeader("Content-Type") != null);
}

test "Request: setHeader overwrites an existing key" {
    const req = try newRequest(.GET, "/");
    defer req.deinit();

    try req.setHeader("Accept", "text/html");
    try req.setHeader("Accept", "application/json");

    try testing.expectEqualStrings("application/json", req.getHeader("Accept").?);
    try testing.expectEqual(@as(usize, 1), req.header.?.count());
}

test "Request: getHeader returns null for an unset key" {
    const req = try newRequest(.GET, "/");
    defer req.deinit();

    try req.setHeader("Accept", "*/*");

    try testing.expect(req.getHeader("Authorization") == null);
}

test "Request: setStatus updates the status" {
    const req = try newRequest(.GET, "/");
    defer req.deinit();

    req.setStatus(.not_found);
    try testing.expectEqual(std.http.Status.not_found, req.status);

    req.setStatus(.internal_server_error);
    try testing.expectEqual(std.http.Status.internal_server_error, req.status);
}

test "Request: reset clears target, query and status" {
    const req = try newRequest(.POST, "/submit?a=1");
    defer req.deinit();

    req.query = .{ .raw = "a=1" };
    req.setStatus(.created);

    req.reset();

    try testing.expectEqualStrings("", req.target);
    try testing.expect(req.query == null);
    try testing.expectEqual(std.http.Status.ok, req.status);
}

test "Request: headers survive reset for object-pool reuse" {
    const req = try newRequest(.GET, "/first");
    defer req.deinit();

    try req.setHeader("X-Pooled", "yes");
    req.reset();

    // `reset` deliberately leaves the map allocated: it is overwritten on
    // next use rather than torn down and rebuilt on every request.
    try testing.expect(req.header_initialized);
    try testing.expectEqualStrings("yes", req.getHeader("X-Pooled").?);
}

test "Request: reusable after reset" {
    const req = try newRequest(.GET, "/first");
    defer req.deinit();

    req.reset();
    req.target = "/second";
    req.method = .PUT;
    try req.setHeader("X-Second", "1");

    try testing.expectEqualStrings("/second", req.target);
    try testing.expectEqual(std.http.Method.PUT, req.method);
    try testing.expectEqualStrings("1", req.getHeader("X-Second").?);
}

test "Request: every HTTP method round-trips" {
    const methods = [_]std.http.Method{
        .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS, .HEAD, .CONNECT, .TRACE,
    };

    for (methods) |method| {
        const req = try newRequest(method, "/any");
        defer req.deinit();
        try testing.expectEqual(method, req.method);
    }
}

test "Request: head carries content metadata" {
    const req = try Request.init(.{
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
    defer req.deinit();

    try testing.expectEqualStrings("application/x-www-form-urlencoded", req.head.content_type.?);
    try testing.expectEqual(@as(u64, 11), req.head.content_length.?);
    try testing.expect(req.head.keep_alive);
}

test "Request: deinit of a request that never allocated headers does not leak" {
    // Guards the `header_initialized` branch in `deinit`; the testing
    // allocator fails the test if the branch is wrong.
    for (0..8) |_| {
        const req = try newRequest(.GET, "/");
        req.deinit();
    }
}
