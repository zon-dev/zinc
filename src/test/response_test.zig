//! Tests for `zinc.Response`.
//!
//! Key behaviours pinned down here:
//!   * `setBody` replaces (and frees) any previous body; `appendBody` concatenates
//!   * `setHeader` *appends*, so it can produce duplicates — unlike `Headers.set`
//!   * `isKeepAlive` is false only when an explicit `Connection: close` is present
//!   * `reset` (object-pool path) frees the body but retains headers

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Response = zinc.Response;

fn newResponse() !*Response {
    return Response.init(.{ .allocator = testing.allocator });
}

test "Response: initial state" {
    const res = try newResponse();
    defer res.deinit();

    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expect(res.body == null);
    try testing.expectEqual(@as(usize, 0), res.getHeaders().len);
    try testing.expectEqualStrings("HTTP/1.1", res.version);
}

test "Response: init uses the supplied allocator" {
    const res = try newResponse();
    defer res.deinit();

    try testing.expectEqual(testing.allocator.ptr, res.allocator.ptr);
}

test "Response: setStatus" {
    const res = try newResponse();
    defer res.deinit();

    res.setStatus(.not_found);
    try testing.expectEqual(std.http.Status.not_found, res.status);

    res.setStatus(.created);
    try testing.expectEqual(std.http.Status.created, res.status);
}

// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

test "Response: setBody stores an owned copy" {
    const res = try newResponse();
    defer res.deinit();

    var scratch = [_]u8{ 'h', 'i' };
    try res.setBody(&scratch);

    // Mutating the caller's buffer must not affect the stored body.
    scratch[0] = 'H';
    try testing.expectEqualStrings("hi", res.body.?);
}

test "Response: setBody replaces a previous body" {
    const res = try newResponse();
    defer res.deinit();

    try res.setBody("first");
    try res.setBody("second");

    // A leak here would be caught by the testing allocator.
    try testing.expectEqualStrings("second", res.body.?);
}

test "Response: setBody accepts an empty body" {
    const res = try newResponse();
    defer res.deinit();

    try res.setBody("");

    try testing.expect(res.body != null);
    try testing.expectEqualStrings("", res.body.?);
}

test "Response: appendBody sets the body when none exists" {
    const res = try newResponse();
    defer res.deinit();

    try res.appendBody("hello");

    try testing.expectEqualStrings("hello", res.body.?);
}

test "Response: appendBody concatenates onto an existing body" {
    const res = try newResponse();
    defer res.deinit();

    try res.appendBody("Hello");
    try res.appendBody(", ");
    try res.appendBody("world!");

    try testing.expectEqualStrings("Hello, world!", res.body.?);
}

test "Response: appendBody after setBody" {
    const res = try newResponse();
    defer res.deinit();

    try res.setBody("base");
    try res.appendBody("-more");

    try testing.expectEqualStrings("base-more", res.body.?);
}

test "Response: setBody discards anything appended earlier" {
    const res = try newResponse();
    defer res.deinit();

    try res.appendBody("throwaway");
    try res.setBody("final");

    try testing.expectEqualStrings("final", res.body.?);
}

test "Response: appending an empty string is a no-op in content" {
    const res = try newResponse();
    defer res.deinit();

    try res.appendBody("body");
    try res.appendBody("");

    try testing.expectEqualStrings("body", res.body.?);
}

test "Response: body handles binary data including NUL bytes" {
    const res = try newResponse();
    defer res.deinit();

    const payload = [_]u8{ 0x00, 0xFF, 0x10, 0x00, 0x7F };
    try res.setBody(&payload);

    try testing.expectEqualSlices(u8, &payload, res.body.?);
}

test "Response: repeated appends do not leak" {
    const res = try newResponse();
    defer res.deinit();

    for (0..32) |_| try res.appendBody("x");

    try testing.expectEqual(@as(usize, 32), res.body.?.len);
}

// ---------------------------------------------------------------------------
// Headers
// ---------------------------------------------------------------------------

test "Response: setHeader records name and value in order" {
    const res = try newResponse();
    defer res.deinit();

    try res.setHeader("Content-Type", "application/json");
    try res.setHeader("Cache-Control", "no-cache");

    const headers = res.getHeaders();
    try testing.expectEqual(@as(usize, 2), headers.len);
    try testing.expectEqualStrings("Content-Type", headers[0].name);
    try testing.expectEqualStrings("application/json", headers[0].value);
    try testing.expectEqualStrings("Cache-Control", headers[1].name);
    try testing.expectEqualStrings("no-cache", headers[1].value);
}

test "Response: setHeader appends rather than replacing" {
    const res = try newResponse();
    defer res.deinit();

    try res.setHeader("Content-Type", "text/plain");
    try res.setHeader("Content-Type", "application/json");

    // Documents current behaviour: unlike `Headers.set`, this duplicates.
    // Callers that need replace-semantics must go through `Headers`.
    const headers = res.getHeaders();
    try testing.expectEqual(@as(usize, 2), headers.len);
    try testing.expectEqualStrings("text/plain", headers[0].value);
    try testing.expectEqualStrings("application/json", headers[1].value);
}

test "Response: setHeader accepts an empty value" {
    const res = try newResponse();
    defer res.deinit();

    try res.setHeader("X-Empty", "");

    try testing.expectEqual(@as(usize, 1), res.getHeaders().len);
    try testing.expectEqualStrings("", res.getHeaders()[0].value);
}

test "Response: many headers are all retained" {
    const res = try newResponse();
    defer res.deinit();

    const names = [_][]const u8{ "H0", "H1", "H2", "H3", "H4", "H5", "H6", "H7" };
    for (names) |name| try res.setHeader(name, "v");

    try testing.expectEqual(@as(usize, names.len), res.getHeaders().len);
}

// ---------------------------------------------------------------------------
// Keep-alive
// ---------------------------------------------------------------------------

test "Response: isKeepAlive defaults to true with no headers" {
    const res = try newResponse();
    defer res.deinit();

    try testing.expect(res.isKeepAlive());
}

test "Response: isKeepAlive is false with Connection: close" {
    const res = try newResponse();
    defer res.deinit();

    try res.setHeader("Connection", "close");

    try testing.expect(!res.isKeepAlive());
}

test "Response: isKeepAlive is true with Connection: keep-alive" {
    const res = try newResponse();
    defer res.deinit();

    try res.setHeader("Connection", "keep-alive");

    try testing.expect(res.isKeepAlive());
}

test "Response: isKeepAlive matches Connection: close case-insensitively" {
    const res = try newResponse();
    defer res.deinit();

    try res.setHeader("connection", "CLOSE");

    try testing.expect(!res.isKeepAlive());
}

test "Response: unrelated headers do not affect keep-alive" {
    const res = try newResponse();
    defer res.deinit();

    try res.setHeader("Content-Type", "text/plain");
    try res.setHeader("X-Closed", "close");

    try testing.expect(res.isKeepAlive());
}

test "Response: a later Connection: close wins over keep-alive" {
    const res = try newResponse();
    defer res.deinit();

    try res.setHeader("Connection", "keep-alive");
    try res.setHeader("Connection", "close");

    // Any `close` entry disables keep-alive regardless of position.
    try testing.expect(!res.isKeepAlive());
}

// ---------------------------------------------------------------------------
// Object-pool reset
// ---------------------------------------------------------------------------

test "Response: reset clears the body and status" {
    const res = try newResponse();
    defer res.deinit();

    try res.setBody("payload");
    res.setStatus(.internal_server_error);

    res.reset();

    try testing.expect(res.body == null);
    try testing.expectEqual(std.http.Status.ok, res.status);
}

test "Response: reset clears async engine and connection pointers" {
    const res = try newResponse();
    defer res.deinit();

    var engine_marker: usize = 1;
    var conn_marker: usize = 2;
    res.engine = &engine_marker;
    res.connection = &conn_marker;

    res.reset();

    try testing.expect(res.engine == null);
    try testing.expect(res.connection == null);
}

test "Response: reset retains headers for pool reuse" {
    const res = try newResponse();
    defer res.deinit();

    try res.setHeader("X-Pooled", "yes");
    res.reset();

    // Documented behaviour: headers are overwritten on next use rather than
    // cleared, to keep the hot path allocation-free.
    try testing.expectEqual(@as(usize, 1), res.getHeaders().len);
}

test "Response: reusable after reset" {
    const res = try newResponse();
    defer res.deinit();

    try res.setBody("first");
    res.reset();
    try res.setBody("second");

    try testing.expectEqualStrings("second", res.body.?);
}

test "Response: repeated reset cycles do not leak" {
    const res = try newResponse();
    defer res.deinit();

    for (0..16) |_| {
        try res.setBody("cycle");
        res.reset();
    }

    try testing.expect(res.body == null);
}
