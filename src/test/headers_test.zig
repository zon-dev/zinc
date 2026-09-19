//! `zinc.Headers`: ordered, case-insensitive collection.
//!
//! `add` appends (duplicates allowed); `set` replaces the first match and
//! moves it to the end; `remove` of an absent name is a no-op.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Headers = zinc.Headers;

fn newHeaders() Headers {
    return Headers.init(.{ .allocator = testing.allocator });
}

test "Headers: starts empty" {
    var headers = newHeaders();
    defer headers.deinit();

    try testing.expectEqual(@as(usize, 0), headers.len());
    try testing.expectEqual(@as(usize, 0), headers.items().len);
    try testing.expect(headers.get("Content-Type") == null);
}

test "Headers: add then get" {
    var headers = newHeaders();
    defer headers.deinit();

    try headers.add("Content-Type", "text/html");
    try headers.add("Content-Length", "100");

    try testing.expectEqual(@as(usize, 2), headers.len());
    try testing.expectEqualStrings("Content-Type", headers.get("Content-Type").?.name);
    try testing.expectEqualStrings("text/html", headers.get("Content-Type").?.value);
    try testing.expectEqualStrings("100", headers.get("Content-Length").?.value);
}

test "Headers: get is case-insensitive and preserves stored casing" {
    var headers = newHeaders();
    defer headers.deinit();
    try headers.add("X-Custom-Header", "application/json");

    const lookups = [_][]const u8{ "x-custom-header", "X-CUSTOM-HEADER", "X-Custom-Header", "x-CuStOm-HeAdEr" };
    for (lookups) |name| {
        const h = headers.get(name) orelse return error.TestExpectedHeader;
        try testing.expectEqualStrings("application/json", h.value);
        try testing.expectEqualStrings("X-Custom-Header", h.name);
    }

    try testing.expect(headers.get("Accept-Encoding") == null);
    try testing.expect(headers.get("") == null);
}

test "Headers: add permits duplicates and get returns the first" {
    var headers = newHeaders();
    defer headers.deinit();

    try headers.add("Set-Cookie", "a=1");
    try headers.add("Set-Cookie", "b=2");

    try testing.expectEqual(@as(usize, 2), headers.len());
    try testing.expectEqualStrings("a=1", headers.get("Set-Cookie").?.value);
}

test "Headers: set replaces, inserts, and moves to the end" {
    var headers = newHeaders();
    defer headers.deinit();

    try headers.set("X-Request-Id", "abc123");
    try testing.expectEqualStrings("abc123", headers.get("X-Request-Id").?.value);

    try headers.add("Content-Length", "100");
    try headers.set("Content-Length", "200");
    try testing.expectEqual(@as(usize, 2), headers.len());
    try testing.expectEqualStrings("200", headers.get("Content-Length").?.value);

    var ordered = newHeaders();
    defer ordered.deinit();
    try ordered.add("A", "1");
    try ordered.add("B", "2");
    try ordered.add("C", "3");
    try ordered.set("A", "updated");
    try testing.expectEqualStrings("B", ordered.items()[0].name);
    try testing.expectEqualStrings("C", ordered.items()[1].name);
    try testing.expectEqualStrings("A", ordered.items()[2].name);
    try testing.expectEqualStrings("updated", ordered.items()[2].value);
}

test "Headers: set matches case-insensitively but stores the new casing" {
    var headers = newHeaders();
    defer headers.deinit();

    try headers.add("Content-Type", "text/plain");
    try headers.set("content-type", "text/html");

    try testing.expectEqual(@as(usize, 1), headers.len());
    try testing.expectEqualStrings("content-type", headers.items()[0].name);
    try testing.expectEqualStrings("text/html", headers.items()[0].value);
}

test "Headers: set only replaces the first of several duplicates" {
    var headers = newHeaders();
    defer headers.deinit();

    try headers.add("Set-Cookie", "a=1");
    try headers.add("Set-Cookie", "b=2");
    try headers.set("Set-Cookie", "c=3");

    try testing.expectEqual(@as(usize, 2), headers.len());
    try testing.expectEqualStrings("b=2", headers.items()[0].value);
    try testing.expectEqualStrings("c=3", headers.items()[1].value);
}

test "Headers: remove is case-insensitive, a no-op when absent, and order-preserving" {
    var headers = newHeaders();
    defer headers.deinit();

    try headers.add("A", "1");
    try headers.add("B", "2");
    try headers.add("C", "3");
    try headers.remove("b");
    try headers.remove("Nope");

    try testing.expectEqual(@as(usize, 2), headers.len());
    try testing.expectEqualStrings("A", headers.items()[0].name);
    try testing.expectEqualStrings("C", headers.items()[1].name);
    try testing.expect(headers.get("Content-Length") == null);
}

test "Headers: remove drops only the first duplicate" {
    var headers = newHeaders();
    defer headers.deinit();

    try headers.add("Set-Cookie", "a=1");
    try headers.add("Set-Cookie", "b=2");
    try headers.remove("Set-Cookie");

    try testing.expectEqual(@as(usize, 1), headers.len());
    try testing.expectEqualStrings("b=2", headers.get("Set-Cookie").?.value);
}

test "Headers: clear empties the collection and leaves it reusable" {
    var headers = newHeaders();
    defer headers.deinit();

    try headers.add("A", "1");
    try headers.add("B", "2");
    headers.clear();
    try testing.expectEqual(@as(usize, 0), headers.len());
    try testing.expect(headers.get("A") == null);

    try headers.add("B", "2");
    try testing.expectEqual(@as(usize, 1), headers.len());
    try testing.expectEqualStrings("2", headers.get("B").?.value);
}

test "Headers: empty values are preserved" {
    var headers = newHeaders();
    defer headers.deinit();
    try headers.add("X-Empty", "");
    try testing.expectEqualStrings("", headers.get("X-Empty").?.value);
}

test "Headers: getHeaders and items expose the same backing slice" {
    var headers = newHeaders();
    defer headers.deinit();
    try headers.add("A", "1");
    try headers.add("B", "2");

    const via_get = headers.getHeaders();
    const via_items = headers.items();
    try testing.expectEqual(via_get.len, via_items.len);
    try testing.expectEqual(via_get.ptr, via_items.ptr);
}

test "Headers: capacity grows to hold many headers" {
    var headers = newHeaders();
    defer headers.deinit();

    const names = [_][]const u8{ "H0", "H1", "H2", "H3", "H4", "H5", "H6", "H7", "H8", "H9" };
    for (names) |name| try headers.add(name, "v");

    try testing.expectEqual(@as(usize, names.len), headers.len());
    try testing.expect(headers.capacity() >= names.len);
    for (names) |name| try testing.expect(headers.get(name) != null);
}
