//! `zinc.Context` — per-request handle.
//!
//! `text` *appends* to the body; `html` and `json` *replace* it. That
//! asymmetry is what lets a middleware chain build a body up.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Context = zinc.Context;
const Param = zinc.Param;
const harness = @import("harness.zig");

test "Context: query values, arrays and maps" {
    var tc = try harness.newContext(testing.allocator, .{
        .target = "/query?id=1234&message=hello&message=world&ids[a]=1234&ids[b]=hello&ids[b]=world",
    });
    defer tc.deinit();

    var qm = tc.ctx.getQueryMap() orelse return error.TestExpectedQueryMap;
    try testing.expectEqualStrings("1234", qm.get("id").?.items[0]);
    try testing.expectEqualStrings("hello", qm.get("message").?.items[0]);
    try testing.expectEqualStrings("world", qm.get("message").?.items[1]);

    try testing.expectEqualStrings("1234", (try tc.ctx.queryValues("id")).items[0]);
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

test "Context: query lookup contract" {
    {
        var tc = try harness.newContext(testing.allocator, .{ .target = "/search?q=zinc&page=2&q=second" });
        defer tc.deinit();
        try testing.expectEqualStrings("zinc", tc.ctx.getQuery("q").?);
        try testing.expectEqualStrings("2", tc.ctx.getQuery("page").?);
        try testing.expect(tc.ctx.getQuery("missing") == null);
    }
    {
        var tc = try harness.newContext(testing.allocator, .{ .target = "/post?name=foo" });
        defer tc.deinit();
        try testing.expectEqualStrings("foo", try tc.ctx.queryString("name"));
        try testing.expectError(Context.queryError.NotFound, tc.ctx.queryString("other"));
        try testing.expectError(Context.queryError.NotFound, tc.ctx.queryValues("other"));
        try testing.expectError(Context.queryError.NotFound, tc.ctx.queryArray("other"));
    }

    var multi = try harness.newContext(testing.allocator, .{ .target = "/post?name=foo&name=bar" });
    defer multi.deinit();
    try testing.expectError(Context.queryError.MultipleValues, multi.ctx.queryString("name"));

    var plain = try harness.newContext(testing.allocator, .{ .target = "/plain" });
    defer plain.deinit();
    try testing.expect(plain.ctx.getQuery("anything") == null);
    try testing.expect(plain.ctx.queryMap("anything") == null);

    var prefix = try harness.newContext(testing.allocator, .{ .target = "/query?ids[a]=1" });
    defer prefix.deinit();
    try testing.expect(prefix.ctx.queryMap("other") == null);

    var cached = try harness.newContext(testing.allocator, .{ .target = "/query?a=1" });
    defer cached.deinit();
    const first = cached.ctx.getQueryMap() orelse return error.TestExpectedQueryMap;
    const second = cached.ctx.getQueryMap() orelse return error.TestExpectedQueryMap;
    try testing.expectEqual(first.count(), second.count());
    try testing.expect(cached.ctx.query_map != null);
}

test "Context: status, headers and body" {
    var tc = try harness.newContext(testing.allocator, .{});
    defer tc.deinit();

    try testing.expectEqualStrings("", tc.ctx.getBody());
    try tc.ctx.setStatus(.not_found);
    try harness.expectStatus(tc.ctx, .not_found);
    try tc.ctx.status(.teapot);
    try harness.expectStatus(tc.ctx, .teapot);

    try tc.ctx.setBody("Hello Zinc!");
    try harness.expectBody(tc.ctx, "Hello Zinc!");
    try testing.expectEqualStrings("Hello Zinc!", tc.ctx.getBody());

    try tc.ctx.setHeader("Accept", "application/json");
    try harness.expectHeader(tc.ctx, "Accept", "application/json");
    try tc.ctx.setHeader("X-Two", "2");
    try testing.expectEqual(@as(usize, 2), tc.ctx.getHeaders().len);

    try tc.ctx.text("Hi Zinc!", .{ .status = .ok });
    try harness.expectStatus(tc.ctx, .ok);
    try harness.expectBody(tc.ctx, "Hello Zinc!Hi Zinc!");
}

test "Context: getMethod reports the request method" {
    for (harness.methods) |method| {
        var tc = try harness.newContext(testing.allocator, .{ .method = method });
        defer tc.deinit();
        try testing.expectEqual(method, tc.ctx.getMethod());
    }
}

test "Context: text / html content-type helpers" {
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.text("hello", .{});
        try harness.expectHeader(tc.ctx, "Content-Type", "text/plain");
        try harness.expectBody(tc.ctx, "hello");
        try harness.expectStatus(tc.ctx, .ok);
        try harness.expectNoHeader(tc.ctx, "Connection");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.text("nope", .{ .status = .forbidden });
        try harness.expectStatus(tc.ctx, .forbidden);
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.text("hi", .{ .keep_alive = true });
        try harness.expectHeader(tc.ctx, "Connection", "keep-alive");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.html("<h1>Zinc</h1>", .{});
        try harness.expectHeader(tc.ctx, "Content-Type", "text/html");
        try harness.expectBody(tc.ctx, "<h1>Zinc</h1>");
        try tc.ctx.html("<p>second</p>", .{});
        try harness.expectBody(tc.ctx, "<p>second</p>");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.html("<h1>gone</h1>", .{ .status = .gone, .keep_alive = true });
        try harness.expectStatus(tc.ctx, .gone);
        try harness.expectHeader(tc.ctx, "Connection", "keep-alive");
    }
}

test "Context: json serializes structs, arrays, optionals and escapes" {
    const Data = struct { message: []const u8, count: i32, active: bool };
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.json(Data{ .message = "Hello, Zinc!", .count = 42, .active = true }, .{ .status = .ok });
        try harness.expectStatus(tc.ctx, .ok);
        try harness.expectHeader(tc.ctx, "Content-Type", "application/json");
        try harness.expectBodyContains(tc.ctx, "\"message\"");
        try harness.expectBodyContains(tc.ctx, "Hello, Zinc!");
        try harness.expectBodyContains(tc.ctx, "42");
        try harness.expectBodyContains(tc.ctx, "true");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.json(.{ .user = .{ .name = "Zinc User", .age = @as(i32, 25) }, .status = "active" }, .{ .status = .created });
        try harness.expectStatus(tc.ctx, .created);
        try harness.expectBodyContains(tc.ctx, "Zinc User");
        try harness.expectBodyContains(tc.ctx, "25");
        try harness.expectBodyContains(tc.ctx, "active");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        const items = [_][]const u8{ "item1", "item2", "item3" };
        try tc.ctx.json(.{ .items = &items, .total = @as(i32, 3) }, .{});
        try harness.expectBodyContains(tc.ctx, "item1");
        try harness.expectBodyContains(tc.ctx, "item3");
        try harness.expectBodyContains(tc.ctx, "3");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.json(.{ .ok = true, .code = @as(i32, 200) }, .{});
        try harness.expectBodyContains(tc.ctx, "\"ok\"");
        try harness.expectBodyContains(tc.ctx, "200");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.json(.{ .name = @as(?[]const u8, "zinc"), .note = @as(?[]const u8, null) }, .{});
        try harness.expectBodyContains(tc.ctx, "zinc");
        try harness.expectBodyContains(tc.ctx, "null");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.json(.{ .text = "quote\" back\\slash" }, .{});
        try harness.expectBodyContains(tc.ctx, "\\\"");
        try harness.expectBodyContains(tc.ctx, "\\\\");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.json(.{}, .{});
        try harness.expectBody(tc.ctx, "{}");
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.text("plain first", .{});
        try tc.ctx.json(.{ .replaced = true }, .{});
        try harness.expectBodyContains(tc.ctx, "replaced");
        try testing.expect(std.mem.indexOf(u8, tc.ctx.response.body.?, "plain first") == null);
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.json(.{ .a = @as(i32, 1) }, .{ .keep_alive = true });
        try harness.expectHeader(tc.ctx, "Connection", "keep-alive");
    }
}

test "Context: file and dir serving" {
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.file(harness.assets.style_css, .{});
        try harness.expectBody(tc.ctx, harness.assets.style_css_body);
        try harness.expectStatus(tc.ctx, .ok);
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try tc.ctx.file(harness.assets.style_css, .{ .status = .accepted });
        try harness.expectStatus(tc.ctx, .accepted);
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try testing.expectError(error.FileNotFound, tc.ctx.file("src/test/assets/nope.css", .{}));
        try testing.expectError(error.NotFound, tc.ctx.file("src/test/assets/", .{}));
    }
    {
        var tc = try harness.newContext(testing.allocator, .{ .target = "/assets/style.css" });
        defer tc.deinit();
        try tc.ctx.dir(harness.assets.dir, .{});
        try harness.expectBody(tc.ctx, harness.assets.style_css_body);
    }
    {
        var tc = try harness.newContext(testing.allocator, .{ .target = "/assets/js/script.js" });
        defer tc.deinit();
        try tc.ctx.dir(harness.assets.dir, .{});
        try harness.expectBody(tc.ctx, harness.assets.script_js_body);
    }
    {
        var tc = try harness.newContext(testing.allocator, .{ .target = "/assets/missing.css" });
        defer tc.deinit();
        try testing.expectError(error.FileNotFound, tc.ctx.dir(harness.assets.dir, .{}));
    }
}

test "Context: params storage contract" {
    var tc = try harness.newContext(testing.allocator, .{ .target = "/user/7/posts/13" });
    defer tc.deinit();

    try testing.expect(tc.ctx.getParam("id") == null);
    try testing.expectEqual(@as(u32, 0), tc.ctx.params.count());

    try tc.ctx.params.put("id", .{ .name = "id", .value = "7" });
    try tc.ctx.params.put("postId", .{ .name = "postId", .value = "13" });
    try testing.expectEqualStrings("7", tc.ctx.getParam("id").?.value);
    try testing.expectEqualStrings("13", tc.ctx.getParam("postId").?.value);
    try testing.expect(tc.ctx.getParam("other") == null);

    const empty: Param = .{};
    try testing.expectEqualStrings("", empty.name);
    try testing.expectEqualStrings("", empty.value);
}

test "Context: handler chain" {
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        defer tc.ctx.handlers.deinit();
        try tc.ctx.handlersProcess();
        try harness.expectNoBody(tc.ctx);
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        defer tc.ctx.handlers.deinit();
        try tc.ctx.handlers.append(harness.text("only"));
        try tc.ctx.handlersProcess();
        try harness.expectBody(tc.ctx, "only");
        try tc.ctx.handlersProcess();
        try harness.expectBody(tc.ctx, "onlyonly");
    }

    harness.Trace.reset();
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        defer tc.ctx.handlers.deinit();
        try tc.ctx.handlers.append(harness.tracingMiddleware("outer"));
        try tc.ctx.handlers.append(harness.tracingMiddleware("inner"));
        try tc.ctx.handlers.append(harness.tracingHandler("final", "done"));
        try tc.ctx.handlersProcess();
        try harness.Trace.expectOrder(&.{ "outer:before", "inner:before", "final", "inner:after", "outer:after" });
        try harness.expectBody(tc.ctx, "done");
    }

    harness.Trace.reset();
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        defer tc.ctx.handlers.deinit();
        try tc.ctx.handlers.append(harness.tracingHandler("first", "stop"));
        try tc.ctx.handlers.append(harness.tracingHandler("never", "unreachable"));
        try tc.ctx.handlersProcess();
        try harness.Trace.expectOrder(&.{"first"});
        try harness.expectBody(tc.ctx, "stop");
    }

    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        defer tc.ctx.handlers.deinit();
        try tc.ctx.handlers.append(harness.failingHandler(error.Boom));
        try testing.expectError(error.Boom, tc.ctx.handlersProcess());
    }
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        defer tc.ctx.handlers.deinit();
        try tc.ctx.handlers.append(harness.tracingMiddleware("outer"));
        try tc.ctx.handlers.append(harness.failingHandler(error.Inner));
        try testing.expectError(error.Inner, tc.ctx.handlersProcess());
    }

    harness.Trace.reset();
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        defer tc.ctx.handlers.deinit();
        try tc.ctx.handlers.append(harness.tracingMiddleware("solo"));
        try tc.ctx.handlersProcess();
        try harness.Trace.expectOrder(&.{ "solo:before", "solo:after" });
    }

    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        defer tc.ctx.handlers.deinit();
        const prefix = struct {
            fn handle(ctx: *Context) anyerror!void {
                try ctx.text("Hello ", .{});
                try ctx.next();
            }
        }.handle;
        const suffix = struct {
            fn handle(ctx: *Context) anyerror!void {
                try ctx.next();
                try ctx.text("!", .{});
            }
        }.handle;
        try tc.ctx.handlers.append(prefix);
        try tc.ctx.handlers.append(suffix);
        try tc.ctx.handlers.append(harness.text("world"));
        try tc.ctx.handlersProcess();
        try harness.expectBody(tc.ctx, "Hello world!");
    }

    {
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
}

test "Context: form bodies" {
    {
        var tc = try harness.newContext(testing.allocator, .{});
        defer tc.deinit();
        try testing.expect(try tc.ctx.getPostFormMap() == null);
        try testing.expect(try tc.ctx.postFormMap("user") == null);
    }
    {
        var body = "a=1".*;
        var tc = try harness.newContext(testing.allocator, .{
            .method = .POST,
            .recv_buf = &body,
            .content_type = "application/json",
        });
        defer tc.deinit();
        try testing.expect(try tc.ctx.getPostFormMap() == null);
    }
    {
        var body = "a=1".*;
        var tc = try harness.newContext(testing.allocator, .{
            .method = .POST,
            .recv_buf = &body,
            .content_type = "application/x-www-form-urlencoded",
            .content_length = 512,
        });
        defer tc.deinit();
        try testing.expect(try tc.ctx.getPostFormMap() == null);
    }
    {
        var body = "name=zinc&lang=zig".*;
        var tc = try harness.newFormContext(testing.allocator, .POST, "/submit", &body);
        defer tc.deinit();
        var form = try tc.ctx.getPostFormMap() orelse return error.TestExpectedForm;
        defer form.deinit();
        try testing.expectEqualStrings("zinc", form.get("name").?);
        try testing.expectEqualStrings("zig", form.get("lang").?);
        try testing.expect(form.get("missing") == null);
    }

    // KNOWN ISSUE: `postFormMap` never frees the intermediate map from
    // `getPostFormMap`. Arena reclaims it; move to `testing.allocator` once fixed.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var body = "name[first]=foo&name[last]=bar&other[x]=1".*;
        var tc = try harness.newFormContext(arena.allocator(), .POST, "/submit", &body);
        defer tc.deinit();
        var grouped = try tc.ctx.postFormMap("name") orelse return error.TestExpectedForm;
        defer grouped.deinit();
        try testing.expectEqualStrings("foo", grouped.get("first").?);
        try testing.expectEqualStrings("bar", grouped.get("last").?);
        try testing.expect(grouped.get("x") == null);
    }
}
