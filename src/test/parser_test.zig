//! Tests for `Router.Parser`, the request-line parser.
//!
//! It reads just enough of a request to route it: the method and the target.
//! Two behaviours to keep in mind while reading these tests:
//!
//!   * `parseMethod` needs at least 8 bytes before it will commit to a method,
//!     and both `parseMethod` and `parseTarget` return `false` (rather than
//!     erroring) when the buffer is too short. `parse` stops at the first
//!     `false`, so a short buffer returns `false` having set nothing.
//!   * For an unrecognised-but-well-formed method, `parser.method` is left
//!     `undefined`. Tests must not read it in that case, so the assertions
//!     below only cover the target.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Parser = zinc.Router.Parser;

/// Parse `text` (copied into a mutable buffer, as the parser requires).
fn parseInto(buf: []u8) !Parser {
    var parser = Parser.init(buf);
    _ = try parser.parse();
    return parser;
}

test "Parser: init records the buffer" {
    var buf = "GET / HTTP/1.1\r\n".*;
    const parser = Parser.init(&buf);

    try testing.expectEqual(@as(usize, 0), parser.pos);
    try testing.expectEqual(buf.len, parser.len);
}

// ---------------------------------------------------------------------------
// Methods
// ---------------------------------------------------------------------------

test "Parser: GET" {
    var buf = "GET / HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.GET, parser.method);
    try testing.expectEqualStrings("/", parser.target);
}

test "Parser: PUT" {
    var buf = "PUT /resource HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.PUT, parser.method);
    try testing.expectEqualStrings("/resource", parser.target);
}

test "Parser: POST" {
    var buf = "POST /submit HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.POST, parser.method);
    try testing.expectEqualStrings("/submit", parser.target);
}

test "Parser: HEAD" {
    var buf = "HEAD /page HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.HEAD, parser.method);
    try testing.expectEqualStrings("/page", parser.target);
}

test "Parser: PATCH" {
    var buf = "PATCH /item HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.PATCH, parser.method);
    try testing.expectEqualStrings("/item", parser.target);
}

test "Parser: DELETE" {
    var buf = "DELETE /item HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.DELETE, parser.method);
    try testing.expectEqualStrings("/item", parser.target);
}

test "Parser: OPTIONS" {
    var buf = "OPTIONS /thing HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.OPTIONS, parser.method);
    try testing.expectEqualStrings("/thing", parser.target);
}

test "Parser: CONNECT" {
    var buf = "CONNECT /tunnel HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.CONNECT, parser.method);
    try testing.expectEqualStrings("/tunnel", parser.target);
}

test "Parser: a lowercase method is rejected" {
    var buf = "get / HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.UnknownMethod, parser.parse());
}

test "Parser: a mixed-case method is rejected" {
    var buf = "Get / HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.UnknownMethod, parser.parse());
}

test "Parser: POST without a trailing space is rejected" {
    var buf = "POSTX / HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.UnknownMethod, parser.parse());
}

test "Parser: HEAD without a trailing space is rejected" {
    var buf = "HEADER / HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.UnknownMethod, parser.parse());
}

test "Parser: PATCH with a wrong fifth byte is rejected" {
    var buf = "PATCX / HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.UnknownMethod, parser.parse());
}

test "Parser: a truncated DELETE is rejected" {
    var buf = "DELETX / HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.UnknownMethod, parser.parse());
}

test "Parser: a truncated OPTIONS is rejected" {
    var buf = "OPTIONX / HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.UnknownMethod, parser.parse());
}

test "Parser: a truncated CONNECT is rejected" {
    var buf = "CONNECX / HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.UnknownMethod, parser.parse());
}

test "Parser: a leading space is rejected" {
    var buf = " GET / HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.UnknownMethod, parser.parse());
}

test "Parser: an unrecognised uppercase method still yields a target" {
    // Falls through to the generic branch: the method is skipped but left
    // unset, so only the target is asserted here.
    var buf = "PROPFIND /dav HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqualStrings("/dav", parser.target);
}

// ---------------------------------------------------------------------------
// Targets
// ---------------------------------------------------------------------------

test "Parser: a nested path target" {
    var buf = "GET /api/v1/users HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqualStrings("/api/v1/users", parser.target);
}

test "Parser: a target keeps its query string" {
    var buf = "GET /search?q=zinc&page=2 HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    // Query stripping happens later, in `Router.getRoute`.
    try testing.expectEqualStrings("/search?q=zinc&page=2", parser.target);
}

test "Parser: a target keeps a fragment" {
    var buf = "GET /page#section HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqualStrings("/page#section", parser.target);
}

test "Parser: a target with percent-encoded characters" {
    var buf = "GET /a%20b/c HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqualStrings("/a%20b/c", parser.target);
}

test "Parser: a long target" {
    var buf = "GET /a/very/long/path/that/keeps/going/for/a/while HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqualStrings("/a/very/long/path/that/keeps/going/for/a/while", parser.target);
}

test "Parser: an asterisk target" {
    var buf = "OPTIONS * HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.OPTIONS, parser.method);
    try testing.expectEqualStrings("*", parser.target);
}

test "Parser: an asterisk not followed by a space is rejected" {
    var buf = "OPTIONS *x HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.InvalidRequestTarget, parser.parse());
}

test "Parser: an absolute-form target is rejected" {
    // Absolute-form (`http://host/path`) is not supported yet.
    var buf = "GET http://example.com/ HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.InvalidRequestTarget, parser.parse());
}

test "Parser: a target not starting with / or * is rejected" {
    var buf = "GET nopath HTTP/1.1\r\n".*;
    var parser = Parser.init(&buf);

    try testing.expectError(error.InvalidRequestTarget, parser.parse());
}

test "Parser: pos advances past the request line" {
    var buf = "GET /abc HTTP/1.1\r\n".*;
    const parser = try parseInto(&buf);

    // 4 bytes of "GET " plus "/abc" and its trailing space.
    try testing.expectEqual(@as(usize, 9), parser.pos);
}

test "Parser: a request line with headers after it parses fine" {
    var buf = "GET /path HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n\r\n".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.GET, parser.method);
    try testing.expectEqualStrings("/path", parser.target);
}

test "Parser: a full request with a body parses the request line only" {
    var buf = "POST /submit HTTP/1.1\r\nContent-Length: 7\r\n\r\nname=hi".*;
    const parser = try parseInto(&buf);

    try testing.expectEqual(std.http.Method.POST, parser.method);
    try testing.expectEqualStrings("/submit", parser.target);
}

test "Parser: a buffer shorter than 8 bytes sets nothing" {
    // `parseMethod` bails out early and `parse` stops there, so neither
    // method nor target is populated. Reading `method` here would be
    // undefined behaviour, so only the buffer state is checked.
    var buf = "GET /".*;
    var parser = Parser.init(&buf);

    try testing.expectEqual(false, try parser.parse());
    try testing.expectEqual(@as(usize, 0), parser.pos);
}

test "Parser: a request line with no trailing space after the target" {
    // Without a space the target end cannot be found, so `parseTarget`
    // returns false and leaves `pos` where `parseMethod` left it.
    var buf = "GET /nospaceatend".*;
    var parser = Parser.init(&buf);

    _ = try parser.parse();
    try testing.expectEqual(@as(usize, 4), parser.pos);
}

test "Parser: the same buffer can be parsed repeatedly" {
    var buf = "GET /idempotent HTTP/1.1\r\n".*;

    for (0..3) |_| {
        var parser = Parser.init(&buf);
        _ = try parser.parse();
        try testing.expectEqual(std.http.Method.GET, parser.method);
        try testing.expectEqualStrings("/idempotent", parser.target);
    }
}
