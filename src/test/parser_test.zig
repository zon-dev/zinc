//! `Router.Parser` — request-line method + target.
//!
//! `parseMethod` needs 8 bytes before it commits. Both `parseMethod` and
//! `parseTarget` return `false` (not an error) on a short buffer; `parse`
//! stops at the first `false`. Unrecognised-but-well-formed methods leave
//! `parser.method` unset — tests must not read it.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Parser = zinc.Router.Parser;
const harness = @import("harness.zig");

test "Parser: init records the buffer" {
    var buf = "GET / HTTP/1.1\r\n".*;
    const parser = Parser.init(&buf);
    try testing.expectEqual(@as(usize, 0), parser.pos);
    try testing.expectEqual(buf.len, parser.len);
}

test "Parser: well-formed request lines" {
    const Case = struct {
        line: []const u8,
        method: std.http.Method,
        target: []const u8,
        pos: ?usize = null,
    };
    const cases = [_]Case{
        .{ .line = "GET / HTTP/1.1\r\n", .method = .GET, .target = "/", .pos = 6 },
        .{ .line = "PUT /resource HTTP/1.1\r\n", .method = .PUT, .target = "/resource" },
        .{ .line = "POST /submit HTTP/1.1\r\n", .method = .POST, .target = "/submit" },
        .{ .line = "HEAD /page HTTP/1.1\r\n", .method = .HEAD, .target = "/page" },
        .{ .line = "PATCH /item HTTP/1.1\r\n", .method = .PATCH, .target = "/item" },
        .{ .line = "DELETE /item HTTP/1.1\r\n", .method = .DELETE, .target = "/item" },
        .{ .line = "OPTIONS /thing HTTP/1.1\r\n", .method = .OPTIONS, .target = "/thing" },
        .{ .line = "CONNECT /tunnel HTTP/1.1\r\n", .method = .CONNECT, .target = "/tunnel" },
        .{ .line = "GET /api/v1/users HTTP/1.1\r\n", .method = .GET, .target = "/api/v1/users" },
        .{ .line = "GET /search?q=zinc&page=2 HTTP/1.1\r\n", .method = .GET, .target = "/search?q=zinc&page=2" },
        .{ .line = "GET /page#section HTTP/1.1\r\n", .method = .GET, .target = "/page#section" },
        .{ .line = "GET /a%20b/c HTTP/1.1\r\n", .method = .GET, .target = "/a%20b/c" },
        .{ .line = "GET /a/very/long/path/that/keeps/going/for/a/while HTTP/1.1\r\n", .method = .GET, .target = "/a/very/long/path/that/keeps/going/for/a/while" },
        .{ .line = "OPTIONS * HTTP/1.1\r\n", .method = .OPTIONS, .target = "*" },
        .{ .line = "GET /path HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n\r\n", .method = .GET, .target = "/path" },
        .{ .line = "POST /submit HTTP/1.1\r\nContent-Length: 7\r\n\r\nname=hi", .method = .POST, .target = "/submit" },
        .{ .line = "GET /abc HTTP/1.1\r\n", .method = .GET, .target = "/abc", .pos = 9 },
    };

    inline for (cases) |c| {
        var buf: [c.line.len]u8 = c.line[0..c.line.len].*;
        const parser = try harness.parseInto(&buf);
        try testing.expectEqual(c.method, parser.method);
        try testing.expectEqualStrings(c.target, parser.target);
        if (c.pos) |pos| try testing.expectEqual(pos, parser.pos);
    }
}

test "Parser: rejected methods" {
    const lines = [_][]const u8{
        "get / HTTP/1.1\r\n",
        "Get / HTTP/1.1\r\n",
        "POSTX / HTTP/1.1\r\n",
        "HEADER / HTTP/1.1\r\n",
        "PATCX / HTTP/1.1\r\n",
        "DELETX / HTTP/1.1\r\n",
        "OPTIONX / HTTP/1.1\r\n",
        "CONNECX / HTTP/1.1\r\n",
        " GET / HTTP/1.1\r\n",
    };
    inline for (lines) |line| {
        var buf: [line.len]u8 = line[0..line.len].*;
        var parser = Parser.init(&buf);
        try testing.expectError(error.UnknownMethod, parser.parse());
    }
}

test "Parser: rejected targets" {
    const lines = [_][]const u8{
        "OPTIONS *x HTTP/1.1\r\n",
        "GET http://example.com/ HTTP/1.1\r\n",
        "GET nopath HTTP/1.1\r\n",
    };
    inline for (lines) |line| {
        var buf: [line.len]u8 = line[0..line.len].*;
        var parser = Parser.init(&buf);
        try testing.expectError(error.InvalidRequestTarget, parser.parse());
    }
}

test "Parser: an unrecognised uppercase method still yields a target" {
    var buf = "PROPFIND /dav HTTP/1.1\r\n".*;
    const parser = try harness.parseInto(&buf);
    try testing.expectEqualStrings("/dav", parser.target);
}

test "Parser: a buffer shorter than 8 bytes sets nothing" {
    var buf = "GET /".*;
    var parser = Parser.init(&buf);
    try testing.expectEqual(false, try parser.parse());
    try testing.expectEqual(@as(usize, 0), parser.pos);
}

test "Parser: a request line with no trailing space after the target" {
    var buf = "GET /nospaceatend".*;
    var parser = Parser.init(&buf);
    try testing.expectEqual(false, try parser.parse());
    try testing.expectEqual(@as(usize, 4), parser.pos);
}

test "Parser: the same buffer can be parsed repeatedly" {
    var buf = "GET /idempotent HTTP/1.1\r\n".*;
    for (0..3) |_| {
        const parser = try harness.parseInto(&buf);
        try testing.expectEqual(std.http.Method.GET, parser.method);
        try testing.expectEqualStrings("/idempotent", parser.target);
    }
}
