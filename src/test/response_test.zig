//! `zinc.Response`.
//!
//! `setBody` replaces (and frees); `appendBody` concatenates.
//! `setHeader` *appends* (unlike `Headers.set`).
//! `isKeepAlive` is false only when an explicit `Connection: close` is present.
//! `reset` frees the body but retains headers for the object pool.

const std = @import("std");
const testing = std.testing;

const harness = @import("harness.zig");

fn res() !*harness.Response {
    return harness.newResponse(testing.allocator);
}

test "Response: initial state" {
    const r = try res();
    defer r.deinit();

    try testing.expectEqual(std.http.Status.ok, r.status);
    try testing.expect(r.body == null);
    try testing.expectEqual(@as(usize, 0), r.getHeaders().len);
    try testing.expectEqualStrings("HTTP/1.1", r.version);
    try testing.expectEqual(testing.allocator.ptr, r.allocator.ptr);
}

test "Response: setStatus" {
    const r = try res();
    defer r.deinit();
    r.setStatus(.not_found);
    try testing.expectEqual(std.http.Status.not_found, r.status);
    r.setStatus(.created);
    try testing.expectEqual(std.http.Status.created, r.status);
}

test "Response: setBody stores an owned copy and replaces" {
    const r = try res();
    defer r.deinit();

    var scratch = [_]u8{ 'h', 'i' };
    try r.setBody(&scratch);
    scratch[0] = 'H';
    try testing.expectEqualStrings("hi", r.body.?);

    try r.setBody("second");
    try testing.expectEqualStrings("second", r.body.?);

    try r.setBody("");
    try testing.expectEqualStrings("", r.body.?);
}

test "Response: appendBody concatenates; setBody discards prior appends" {
    const r = try res();
    defer r.deinit();

    try r.appendBody("Hello");
    try r.appendBody(", ");
    try r.appendBody("world!");
    try testing.expectEqualStrings("Hello, world!", r.body.?);

    try r.appendBody("");
    try testing.expectEqualStrings("Hello, world!", r.body.?);

    try r.setBody("final");
    try testing.expectEqualStrings("final", r.body.?);

    try r.appendBody("-more");
    try testing.expectEqualStrings("final-more", r.body.?);
}

test "Response: body handles binary data including NUL bytes" {
    const r = try res();
    defer r.deinit();
    const payload = [_]u8{ 0x00, 0xFF, 0x10, 0x00, 0x7F };
    try r.setBody(&payload);
    try testing.expectEqualSlices(u8, &payload, r.body.?);
}

test "Response: repeated appends do not leak" {
    const r = try res();
    defer r.deinit();
    for (0..32) |_| try r.appendBody("x");
    try testing.expectEqual(@as(usize, 32), r.body.?.len);
}

test "Response: setHeader records in order and appends duplicates" {
    const r = try res();
    defer r.deinit();

    try r.setHeader("Content-Type", "text/plain");
    try r.setHeader("Cache-Control", "no-cache");
    try r.setHeader("Content-Type", "application/json");
    try r.setHeader("X-Empty", "");

    const headers = r.getHeaders();
    try testing.expectEqual(@as(usize, 4), headers.len);
    try testing.expectEqualStrings("Content-Type", headers[0].name);
    try testing.expectEqualStrings("text/plain", headers[0].value);
    try testing.expectEqualStrings("Cache-Control", headers[1].name);
    try testing.expectEqualStrings("application/json", headers[2].value);
    try testing.expectEqualStrings("", headers[3].value);
}

test "Response: many headers are all retained" {
    const r = try res();
    defer r.deinit();
    const names = [_][]const u8{ "H0", "H1", "H2", "H3", "H4", "H5", "H6", "H7" };
    for (names) |name| try r.setHeader(name, "v");
    try testing.expectEqual(@as(usize, names.len), r.getHeaders().len);
}

test "Response: isKeepAlive" {
    const Case = struct { headers: []const [2][]const u8, keep: bool };
    const cases = [_]Case{
        .{ .headers = &.{}, .keep = true },
        .{ .headers = &.{.{ "Connection", "close" }}, .keep = false },
        .{ .headers = &.{.{ "Connection", "keep-alive" }}, .keep = true },
        .{ .headers = &.{.{ "connection", "CLOSE" }}, .keep = false },
        .{ .headers = &.{ .{ "Content-Type", "text/plain" }, .{ "X-Closed", "close" } }, .keep = true },
        .{ .headers = &.{ .{ "Connection", "keep-alive" }, .{ "Connection", "close" } }, .keep = false },
    };

    for (cases) |c| {
        const r = try res();
        defer r.deinit();
        for (c.headers) |h| try r.setHeader(h[0], h[1]);
        try testing.expectEqual(c.keep, r.isKeepAlive());
    }
}

test "Response: reset clears body, status and async pointers; retains headers" {
    const r = try res();
    defer r.deinit();

    try r.setBody("payload");
    r.setStatus(.internal_server_error);
    try r.setHeader("X-Pooled", "yes");
    var engine_marker: usize = 1;
    var conn_marker: usize = 2;
    r.engine = &engine_marker;
    r.connection = &conn_marker;

    r.reset();

    try testing.expect(r.body == null);
    try testing.expectEqual(std.http.Status.ok, r.status);
    try testing.expect(r.engine == null);
    try testing.expect(r.connection == null);
    try testing.expectEqual(@as(usize, 1), r.getHeaders().len);

    try r.setBody("second");
    try testing.expectEqualStrings("second", r.body.?);
}

test "Response: repeated reset cycles do not leak" {
    const r = try res();
    defer r.deinit();
    for (0..16) |_| {
        try r.setBody("cycle");
        r.reset();
    }
    try testing.expect(r.body == null);
}
