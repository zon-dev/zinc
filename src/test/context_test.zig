const std = @import("std");
const URL = @import("url");
const RespondOptions = std.http.Server.Request.RespondOptions;
const Header = std.http.Header;

const zinc = @import("../zinc.zig");
const Request = zinc.Request;
const Response = zinc.Response;
const Context = zinc.Context;
const Config = zinc.Config;
const Headers = zinc.Headers;
const Param = zinc.Param;
const HandlerFn = zinc.HandlerFn;

test "context query" {
    const allocator = std.testing.allocator;
    var ctx = try createContext(allocator, "/query?id=1234&message=hello&message=world&ids[a]=1234&ids[b]=hello&ids[b]=world");
    defer ctx.destroy();

    var qm = ctx.getQueryMap() orelse return try std.testing.expect(false);

    try std.testing.expectEqualStrings(qm.get("id").?.items[0], "1234");
    try std.testing.expectEqualStrings(qm.get("message").?.items[0], "hello");
    try std.testing.expectEqualStrings(qm.get("message").?.items[1], "world");

    const idv = ctx.queryValues("id") catch return try std.testing.expect(false);
    try std.testing.expectEqualStrings(idv.items[0], "1234");

    const messages = ctx.queryArray("message") catch return try std.testing.expect(false);
    try std.testing.expectEqualStrings(messages[0], "hello");
    try std.testing.expectEqualStrings(messages[1], "world");

    var ids: std.StringHashMap(std.array_list.Managed([]const u8)) = ctx.queryMap("ids") orelse return try std.testing.expect(false);
    defer ids.deinit();
    try std.testing.expectEqualStrings(ids.get("a").?.items[0], "1234");
    try std.testing.expectEqualStrings(ids.get("b").?.items[0], "hello");
    try std.testing.expectEqualStrings(ids.get("b").?.items[1], "world");
}

test "context query map" {
    const allocator = std.testing.allocator;
    var ctx = try createContext(allocator, "/query?ids[a]=1234&ids[b]=hello&ids[b]=world");
    defer ctx.destroy();

    var ids: std.StringHashMap(std.array_list.Managed([]const u8)) = ctx.queryMap("ids") orelse return try std.testing.expect(false);
    defer ids.deinit();

    try std.testing.expectEqualStrings(ids.get("a").?.items[0], "1234");
    try std.testing.expectEqualStrings(ids.get("b").?.items[0], "hello");
    try std.testing.expectEqualStrings(ids.get("b").?.items[1], "world");
}

test "context response" {
    const allocator = std.testing.allocator;
    var ctx = try createContext(allocator, "/");
    defer ctx.destroy();

    try ctx.setStatus(.not_found);
    try std.testing.expectEqual(ctx.response.status, .not_found);

    try ctx.setBody("Hello Zinc!");
    try std.testing.expectEqualStrings(ctx.response.body.?, "Hello Zinc!");

    try ctx.setHeader("Accept", "application/json");
    try std.testing.expectEqualStrings(ctx.response.header.items[0].name, "Accept");

    try ctx.text("Hi Zinc!", .{ .status = .ok });
    try std.testing.expectEqual(ctx.response.status, .ok);
    try std.testing.expectEqualStrings(ctx.response.body.?, "Hello Zinc!Hi Zinc!");
}

test "context File" {
    const allocator = std.testing.allocator;
    var ctx = try createContext(allocator, "/");
    defer ctx.destroy();

    try ctx.file("src/test/assets/style.css", .{});
    try std.testing.expectEqualStrings(ctx.response.body.?, "/* style.css */");
}

test "context Directory" {
    const allocator = std.testing.allocator;
    var ctx = try createContext(allocator, "/assets/style.css");
    defer ctx.destroy();

    try ctx.dir("src/test/assets", .{});
    try std.testing.expectEqualStrings(ctx.response.body.?, "/* style.css */");
}

test "context Directory with file" {
    const allocator = std.testing.allocator;
    var ctx = try createContext(allocator, "/assets/js/script.js");
    defer ctx.destroy();

    try ctx.dir("src/test/assets", .{});
    try std.testing.expectEqualStrings(ctx.response.body.?, "// script.js");
}

test "context getPostFormMap function signature change" {
    const allocator = std.testing.allocator;
    var ctx = try createContext(allocator, "/");
    defer ctx.destroy();

    // Test that getPostFormMap now returns !? instead of ?
    // This tests the function signature change from the recent modifications
    const result = try ctx.getPostFormMap();
    try std.testing.expect(result == null); // Should return null for no content type
}

test "context postFormMap function signature change" {
    const allocator = std.testing.allocator;
    var ctx = try createContext(allocator, "/");
    defer ctx.destroy();

    // Test that postFormMap now returns !? instead of ?
    // This tests the function signature change from the recent modifications
    const result = try ctx.postFormMap("user");
    try std.testing.expect(result == null); // Should return null for no content type
}

fn createContext(allocator: std.mem.Allocator, target: []const u8) anyerror!*Context {
    const req = try Request.init(.{ .target = target, .allocator = allocator });
    const res = try Response.init(.{ .allocator = allocator });
    const ctx = try Context.init(.{ .request = req, .response = res, .allocator = allocator });
    return ctx;
}
