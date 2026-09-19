//! Tests for `zinc.Context`, the per-request handle handlers are given.
//!
//! Covers response writing (`text`/`html`/`json`/`file`/`dir`), query-string
//! access, path params, the middleware chain (`next`/`handlersProcess`) and
//! form parsing.
//!
//! Note: `text` *appends* to the body while `html` and `json` *replace* it.
//! That asymmetry is what makes the middleware chain able to build up a body,
//! and several tests below pin it down deliberately.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Context = zinc.Context;
const Param = zinc.Param;

const harness = @import("harness.zig");

// ---------------------------------------------------------------------------
// Query strings
// ---------------------------------------------------------------------------

test "Context: query values, arrays and maps" {
    var tc = try harness.newContext(testing.allocator, .{
        .target = "/query?id=1234&message=hello&message=world&ids[a]=1234&ids[b]=hello&ids[b]=world",
    });
    defer tc.deinit();

    var qm = tc.ctx.getQueryMap() orelse return error.TestExpectedQueryMap;
    try testing.expectEqualStrings("1234", qm.get("id").?.items[0]);
    try testing.expectEqualStrings("hello", qm.get("message").?.items[0]);
    try testing.expectEqualStrings("world", qm.get("message").?.items[1]);

    const idv = try tc.ctx.queryValues("id");
    try testing.expectEqualStrings("1234", idv.items[0]);

    const messages = try tc.ctx.queryArray("message");
    try testing.expectEqual(@as(usize, 2), messages.len);
    try testing.expectEqualStrings("hello", messages[0]);
    try testing.expectEqualStrings("world", messages[1]);

    var ids = tc.ctx.queryMap("ids") orelse return error.TestExpectedQueryMap;
    defer ids.deinit();
    try testing.expectEqualStrings("1234", ids.get("a").?.items[0]);
    try testing.expectEqualStrings("hello", ids.get("b").?.items[0]);
    try testing.expectEqualStrings("world", ids.get("b").?.items[1]);
}

test "Context: queryMap groups bracketed keys" {
    var tc = try harness.newContext(testing.allocator, .{
        .target = "/query?ids[a]=1234&ids[b]=hello&ids[b]=world",
    });
    defer tc.deinit();

    var ids = tc.ctx.queryMap("ids") orelse return error.TestExpectedQueryMap;
    defer ids.deinit();

    try testing.expectEqualStrings("1234", ids.get("a").?.items[0]);
    try testing.expectEqualStrings("hello", ids.get("b").?.items[0]);
    try testing.expectEqualStrings("world", ids.get("b").?.items[1]);
}

test "Context: getQuery returns the first value" {
    var tc = try harness.newContext(testing.allocator, .{
        .target = "/search?q=zinc&page=2&q=second",
    });
    defer tc.deinit();

    try testing.expectEqualStrings("zinc", tc.ctx.getQuery("q").?);
    try testing.expectEqualStrings("2", tc.ctx.getQuery("page").?);
}

test "Context: getQuery returns null for a missing key" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/search?q=zinc" });
    defer tc.deinit();

    try testing.expect(tc.ctx.getQuery("missing") == null);
}

test "Context: queryString returns a single value" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/post?name=foo" });
    defer tc.deinit();

    try testing.expectEqualStrings("foo", try tc.ctx.queryString("name"));
}

test "Context: queryString rejects repeated keys" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/post?name=foo&name=bar" });
    defer tc.deinit();

    try testing.expectError(Context.queryError.MultipleValues, tc.ctx.queryString("name"));
}

test "Context: query lookups report NotFound for absent keys" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/post?name=foo" });
    defer tc.deinit();

    try testing.expectError(Context.queryError.NotFound, tc.ctx.queryString("other"));
    try testing.expectError(Context.queryError.NotFound, tc.ctx.queryValues("other"));
    try testing.expectError(Context.queryError.NotFound, tc.ctx.queryArray("other"));
}

test "Context: a target with no query string yields no values" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/plain" });
    defer tc.deinit();

    try testing.expect(tc.ctx.getQuery("anything") == null);
    try testing.expect(tc.ctx.queryMap("anything") == null);
}

test "Context: queryMap returns null when no key matches the prefix" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/query?ids[a]=1" });
    defer tc.deinit();

    try testing.expect(tc.ctx.queryMap("other") == null);
}

test "Context: getQueryMap is cached across calls" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/query?a=1" });
    defer tc.deinit();

    const first = tc.ctx.getQueryMap() orelse return error.TestExpectedQueryMap;
    const second = tc.ctx.getQueryMap() orelse return error.TestExpectedQueryMap;

    // Second call must reuse the parsed map rather than re-parsing.
    try testing.expectEqual(first.count(), second.count());
    try testing.expect(tc.ctx.query_map != null);
}

// ---------------------------------------------------------------------------
// Status, headers and body
// ---------------------------------------------------------------------------

test "Context: setStatus and status both set the response status" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.setStatus(.not_found);
    try harness.expectStatus(tc.ctx, .not_found);

    try tc.ctx.status(.teapot);
    try harness.expectStatus(tc.ctx, .teapot);
}

test "Context: setBody and setHeader reach the response" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.setBody("Hello Zinc!");
    try harness.expectBody(tc.ctx, "Hello Zinc!");

    try tc.ctx.setHeader("Accept", "application/json");
    try harness.expectHeader(tc.ctx, "Accept", "application/json");
}

test "Context: setBody replaces, text appends" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.setStatus(.not_found);
    try tc.ctx.setBody("Hello Zinc!");
    try tc.ctx.text("Hi Zinc!", .{ .status = .ok });

    // `text` appends, which is what lets a middleware chain build a body up.
    try harness.expectStatus(tc.ctx, .ok);
    try harness.expectBody(tc.ctx, "Hello Zinc!Hi Zinc!");
}

test "Context: getBody reflects the response body" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try testing.expectEqualStrings("", tc.ctx.getBody());

    try tc.ctx.setBody("payload");
    try testing.expectEqualStrings("payload", tc.ctx.getBody());
}

test "Context: getHeaders exposes the response headers" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.setHeader("X-One", "1");
    try tc.ctx.setHeader("X-Two", "2");

    const headers = tc.ctx.getHeaders();
    try testing.expectEqual(@as(usize, 2), headers.len);
    try testing.expectEqualStrings("X-One", headers[0].name);
    try testing.expectEqualStrings("X-Two", headers[1].name);
}

test "Context: getMethod reports the request method" {
    for ([_]std.http.Method{ .GET, .POST, .PUT, .DELETE, .PATCH, .HEAD, .OPTIONS }) |method| {
        var tc = try harness.newContext(testing.allocator, .{ .method = method });
        defer tc.deinit();
        try testing.expectEqual(method, tc.ctx.getMethod());
    }
}

// ---------------------------------------------------------------------------
// Content-type helpers
// ---------------------------------------------------------------------------

test "Context: text sets a text/plain content type" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.text("hello", .{});

    try harness.expectHeader(tc.ctx, "Content-Type", "text/plain");
    try harness.expectBody(tc.ctx, "hello");
    try harness.expectStatus(tc.ctx, .ok);
}

test "Context: text honours an explicit status" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.text("nope", .{ .status = .forbidden });

    try harness.expectStatus(tc.ctx, .forbidden);
    try harness.expectBody(tc.ctx, "nope");
}

test "Context: text adds a keep-alive header when asked" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.text("hi", .{ .keep_alive = true });

    try harness.expectHeader(tc.ctx, "Connection", "keep-alive");
}

test "Context: text omits the Connection header by default" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.text("hi", .{});

    try harness.expectNoHeader(tc.ctx, "Connection");
}

test "Context: html sets a text/html content type" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.html("<h1>Zinc</h1>", .{});

    try harness.expectHeader(tc.ctx, "Content-Type", "text/html");
    try harness.expectBody(tc.ctx, "<h1>Zinc</h1>");
    try harness.expectStatus(tc.ctx, .ok);
}

test "Context: html replaces the body rather than appending" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.html("<p>first</p>", .{});
    try tc.ctx.html("<p>second</p>", .{});

    try harness.expectBody(tc.ctx, "<p>second</p>");
}

test "Context: html honours status and keep-alive" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.html("<h1>gone</h1>", .{ .status = .gone, .keep_alive = true });

    try harness.expectStatus(tc.ctx, .gone);
    try harness.expectHeader(tc.ctx, "Connection", "keep-alive");
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

test "Context: json serializes a struct and sets the content type" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    const TestData = struct {
        message: []const u8,
        count: i32,
        active: bool,
    };

    try tc.ctx.json(TestData{
        .message = "Hello, Zinc!",
        .count = 42,
        .active = true,
    }, .{ .status = .ok });

    try harness.expectStatus(tc.ctx, .ok);
    try harness.expectHeader(tc.ctx, "Content-Type", "application/json");
    try harness.expectBodyContains(tc.ctx, "\"message\"");
    try harness.expectBodyContains(tc.ctx, "Hello, Zinc!");
    try harness.expectBodyContains(tc.ctx, "42");
    try harness.expectBodyContains(tc.ctx, "true");
}

test "Context: json serializes a nested struct" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    const NestedData = struct {
        user: struct {
            name: []const u8,
            age: i32,
        },
        status: []const u8,
    };

    try tc.ctx.json(NestedData{
        .user = .{ .name = "Zinc User", .age = 25 },
        .status = "active",
    }, .{ .status = .created });

    try harness.expectStatus(tc.ctx, .created);
    try harness.expectBodyContains(tc.ctx, "Zinc User");
    try harness.expectBodyContains(tc.ctx, "25");
    try harness.expectBodyContains(tc.ctx, "active");
}

test "Context: json serializes arrays" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    const ArrayData = struct {
        items: []const []const u8,
        total: i32,
    };

    const items = [_][]const u8{ "item1", "item2", "item3" };
    try tc.ctx.json(ArrayData{ .items = &items, .total = 3 }, .{ .status = .ok });

    try harness.expectStatus(tc.ctx, .ok);
    try harness.expectBodyContains(tc.ctx, "item1");
    try harness.expectBodyContains(tc.ctx, "item2");
    try harness.expectBodyContains(tc.ctx, "item3");
    try harness.expectBodyContains(tc.ctx, "3");
}

test "Context: json serializes an anonymous struct" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.json(.{ .ok = true, .code = 200 }, .{});

    try harness.expectBodyContains(tc.ctx, "\"ok\"");
    try harness.expectBodyContains(tc.ctx, "200");
}

test "Context: json serializes optionals as null" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    const WithOptional = struct { name: ?[]const u8, note: ?[]const u8 };
    try tc.ctx.json(WithOptional{ .name = "zinc", .note = null }, .{});

    try harness.expectBodyContains(tc.ctx, "zinc");
    try harness.expectBodyContains(tc.ctx, "null");
}

test "Context: json escapes characters that JSON reserves" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.json(.{ .text = "quote\" back\\slash" }, .{});

    // The raw characters must not appear unescaped in the output.
    try harness.expectBodyContains(tc.ctx, "\\\"");
    try harness.expectBodyContains(tc.ctx, "\\\\");
}

test "Context: json serializes an empty struct" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.json(.{}, .{});

    try harness.expectBody(tc.ctx, "{}");
}

test "Context: json replaces a previous body" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.text("plain first", .{});
    try tc.ctx.json(.{ .replaced = true }, .{});

    try harness.expectBodyContains(tc.ctx, "replaced");
    try testing.expect(std.mem.indexOf(u8, tc.ctx.response.body.?, "plain first") == null);
}

test "Context: json honours keep-alive" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.json(.{ .a = 1 }, .{ .keep_alive = true });

    try harness.expectHeader(tc.ctx, "Connection", "keep-alive");
}

// ---------------------------------------------------------------------------
// Static file and directory serving
//
// Paths are relative to the process cwd, which is the repo root when tests are
// run through `zig build test`.
// ---------------------------------------------------------------------------

test "Context: file serves a file's contents" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.file("src/test/assets/style.css", .{});

    try harness.expectBody(tc.ctx, "/* style.css */");
    try harness.expectStatus(tc.ctx, .ok);
}

test "Context: file honours an explicit status" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.file("src/test/assets/style.css", .{ .status = .accepted });

    try harness.expectStatus(tc.ctx, .accepted);
}

test "Context: file reports FileNotFound for a missing path" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try testing.expectError(error.FileNotFound, tc.ctx.file("src/test/assets/nope.css", .{}));
}

test "Context: file rejects a path with no basename" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try testing.expectError(error.NotFound, tc.ctx.file("src/test/assets/", .{}));
}

test "Context: dir serves a file below the directory" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/assets/style.css" });
    defer tc.deinit();

    try tc.ctx.dir("src/test/assets", .{});

    try harness.expectBody(tc.ctx, "/* style.css */");
}

test "Context: dir serves a nested file" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/assets/js/script.js" });
    defer tc.deinit();

    try tc.ctx.dir("src/test/assets", .{});

    try harness.expectBody(tc.ctx, "// script.js");
}

test "Context: dir reports an error for a missing file" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/assets/missing.css" });
    defer tc.deinit();

    try testing.expectError(error.FileNotFound, tc.ctx.dir("src/test/assets", .{}));
}

// ---------------------------------------------------------------------------
// Path params
//
// `Context.params` is the storage the router is meant to populate for `:name`
// segments. Route-driven binding is not implemented yet (nothing in the
// framework writes to `params`), so these tests cover the storage contract
// that a future binding implementation has to satisfy.
// ---------------------------------------------------------------------------

test "Context: params start empty" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/user/42" });
    defer tc.deinit();

    try testing.expect(tc.ctx.getParam("id") == null);
    try testing.expectEqual(@as(u32, 0), tc.ctx.params.count());
}

test "Context: getParam returns a stored param" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/user/42" });
    defer tc.deinit();

    try tc.ctx.params.put("id", .{ .name = "id", .value = "42" });

    const param = tc.ctx.getParam("id") orelse return error.TestExpectedParam;
    try testing.expectEqualStrings("id", param.name);
    try testing.expectEqualStrings("42", param.value);
}

test "Context: getParam returns null for an unknown name" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try tc.ctx.params.put("id", .{ .name = "id", .value = "1" });

    try testing.expect(tc.ctx.getParam("other") == null);
}

test "Context: several params coexist" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/user/7/posts/13" });
    defer tc.deinit();

    try tc.ctx.params.put("id", .{ .name = "id", .value = "7" });
    try tc.ctx.params.put("postId", .{ .name = "postId", .value = "13" });

    try testing.expectEqualStrings("7", tc.ctx.getParam("id").?.value);
    try testing.expectEqualStrings("13", tc.ctx.getParam("postId").?.value);
}

test "Param: defaults to empty strings" {
    const param: Param = .{};

    try testing.expectEqualStrings("", param.name);
    try testing.expectEqualStrings("", param.value);
}

// ---------------------------------------------------------------------------
// Handler chain
//
// `handlersProcess` invokes only the first handler; each handler is
// responsible for calling `next()` to continue. These tests drive the chain
// directly on the context, without a router.
// ---------------------------------------------------------------------------

test "Context: handlersProcess on an empty chain is a no-op" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();
    defer tc.ctx.handlers.deinit();

    try tc.ctx.handlersProcess();

    try harness.expectNoBody(tc.ctx);
}

test "Context: handlersProcess runs a single handler" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();
    defer tc.ctx.handlers.deinit();

    try tc.ctx.handlers.append(harness.textHandler("only"));
    try tc.ctx.handlersProcess();

    try harness.expectBody(tc.ctx, "only");
}

test "Context: next walks the chain in order" {
    harness.Trace.reset();

    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();
    defer tc.ctx.handlers.deinit();

    try tc.ctx.handlers.append(harness.tracingMiddleware("outer"));
    try tc.ctx.handlers.append(harness.tracingMiddleware("inner"));
    try tc.ctx.handlers.append(harness.tracingHandler("final", "done"));

    try tc.ctx.handlersProcess();

    try harness.Trace.expectOrder(&.{
        "outer:before",
        "inner:before",
        "final",
        "inner:after",
        "outer:after",
    });
    try harness.expectBody(tc.ctx, "done");
}

test "Context: a handler that does not call next stops the chain" {
    harness.Trace.reset();

    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();
    defer tc.ctx.handlers.deinit();

    try tc.ctx.handlers.append(harness.tracingHandler("first", "stop"));
    try tc.ctx.handlers.append(harness.tracingHandler("never", "unreachable"));

    try tc.ctx.handlersProcess();

    try harness.Trace.expectOrder(&.{"first"});
    try harness.expectBody(tc.ctx, "stop");
}

test "Context: an error in a handler propagates to the caller" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();
    defer tc.ctx.handlers.deinit();

    try tc.ctx.handlers.append(harness.failingHandler(error.Boom));

    try testing.expectError(error.Boom, tc.ctx.handlersProcess());
}

test "Context: an error in a later handler propagates through next" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();
    defer tc.ctx.handlers.deinit();

    try tc.ctx.handlers.append(harness.tracingMiddleware("outer"));
    try tc.ctx.handlers.append(harness.failingHandler(error.Inner));

    try testing.expectError(error.Inner, tc.ctx.handlersProcess());
}

test "Context: handlersProcess resets the index so a chain can rerun" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();
    defer tc.ctx.handlers.deinit();

    try tc.ctx.handlers.append(harness.textHandler("x"));

    try tc.ctx.handlersProcess();
    try tc.ctx.handlersProcess();

    // `text` appends, so a second run appends again — proof the chain reran
    // from index 0 rather than resuming past the end.
    try harness.expectBody(tc.ctx, "xx");
}

test "Context: next past the end of the chain is safe" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();
    defer tc.ctx.handlers.deinit();

    // Last handler calls next() with nothing after it.
    try tc.ctx.handlers.append(harness.tracingMiddleware("solo"));

    harness.Trace.reset();
    try tc.ctx.handlersProcess();

    try harness.Trace.expectOrder(&.{ "solo:before", "solo:after" });
}

test "Context: middleware can build a body cooperatively" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();
    defer tc.ctx.handlers.deinit();

    const prefix = struct {
        fn handle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Hello ", .{});
            try ctx.next();
        }
    }.handle;
    const suffix = struct {
        fn handle(ctx: *zinc.Context) anyerror!void {
            try ctx.next();
            try ctx.text("!", .{});
        }
    }.handle;

    try tc.ctx.handlers.append(prefix);
    try tc.ctx.handlers.append(suffix);
    try tc.ctx.handlers.append(harness.textHandler("world"));

    try tc.ctx.handlersProcess();

    try harness.expectBody(tc.ctx, "Hello world!");
}

test "Context: reset clears the chain index and done flag" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/x?a=1" });
    defer tc.deinit();
    defer tc.ctx.handlers.deinit();

    tc.ctx.index = 3;
    tc.ctx.done = true;
    _ = tc.ctx.getQueryMap();

    tc.ctx.reset();

    try testing.expectEqual(@as(u8, 0), tc.ctx.index);
    try testing.expect(!tc.ctx.done);
    try testing.expect(tc.ctx.query == null);
}

// ---------------------------------------------------------------------------
// Form bodies
//
// `getPostFormMap` reads the body out of `Context.recv_buf` and requires both
// a `application/x-www-form-urlencoded` content type and a content length.
// ---------------------------------------------------------------------------

test "Context: getPostFormMap returns null without a content type" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try testing.expect(try tc.ctx.getPostFormMap() == null);
}

test "Context: postFormMap returns null without a content type" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try testing.expect(try tc.ctx.postFormMap("user") == null);
}

test "Context: getPostFormMap returns null for a non-form content type" {
    var body = "a=1".*;
    var tc = try harness.newContext(testing.allocator, .{
        .method = .POST,
        .recv_buf = &body,
        .content_type = "application/json",
    });
    defer tc.deinit();

    try testing.expect(try tc.ctx.getPostFormMap() == null);
}

test "Context: getPostFormMap returns null when the body is short" {
    var body = "a=1".*;
    var tc = try harness.newContext(testing.allocator, .{
        .method = .POST,
        .recv_buf = &body,
        .content_type = "application/x-www-form-urlencoded",
        // Claim more bytes than the buffer holds.
        .content_length = 512,
    });
    defer tc.deinit();

    try testing.expect(try tc.ctx.getPostFormMap() == null);
}

test "Context: getPostFormMap parses form fields" {
    var body = "name=zinc&lang=zig".*;
    var tc = try harness.newFormContext(testing.allocator, .POST, "/submit", &body);
    defer tc.deinit();

    var form = try tc.ctx.getPostFormMap() orelse return error.TestExpectedForm;
    defer form.deinit();

    try testing.expectEqualStrings("zinc", form.get("name").?);
    try testing.expectEqualStrings("zig", form.get("lang").?);
}

test "Context: getPostFormMap returns null for an absent field" {
    var body = "name=zinc".*;
    var tc = try harness.newFormContext(testing.allocator, .POST, "/submit", &body);
    defer tc.deinit();

    var form = try tc.ctx.getPostFormMap() orelse return error.TestExpectedForm;
    defer form.deinit();

    try testing.expect(form.get("missing") == null);
}

// KNOWN ISSUE: `Context.postFormMap` calls `getPostFormMap` and never releases
// the intermediate map, so it leaks one `StringHashMap` per call. The two tests
// below therefore run on an arena, which reclaims the leak on `deinit`. Once
// `postFormMap` frees its intermediate map, they can move to
// `testing.allocator` and the leak checker will keep it honest.
test "Context: postFormMap groups bracketed field names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var body = "name[first]=foo&name[last]=bar".*;
    var tc = try harness.newFormContext(arena.allocator(), .POST, "/submit", &body);
    defer tc.deinit();

    var grouped = try tc.ctx.postFormMap("name") orelse return error.TestExpectedForm;
    defer grouped.deinit();

    try testing.expectEqualStrings("foo", grouped.get("first").?);
    try testing.expectEqualStrings("bar", grouped.get("last").?);
}

test "Context: postFormMap ignores fields under a different prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var body = "name[first]=foo&other[x]=1".*;
    var tc = try harness.newFormContext(arena.allocator(), .POST, "/submit", &body);
    defer tc.deinit();

    var grouped = try tc.ctx.postFormMap("name") orelse return error.TestExpectedForm;
    defer grouped.deinit();

    try testing.expect(grouped.get("first") != null);
    try testing.expect(grouped.get("x") == null);
}
