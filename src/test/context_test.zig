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

    var req = Request.init(.{
        .target = "/query?id=1234&message=hello&message=world&ids[a]=1234&ids[b]=hello&ids[b]=world",
        .allocator = allocator,
    });

    var ctx = try Context.init(.{ .request = &req, .allocator = allocator });
    defer ctx.destroy();

    var qm = ctx.getQueryMap() orelse {
        return try std.testing.expect(false);
    };
    // defer qm.deinit();

    try std.testing.expectEqualStrings(qm.get("id").?.items[0], "1234");
    try std.testing.expectEqualStrings(qm.get("message").?.items[0], "hello");
    try std.testing.expectEqualStrings(qm.get("message").?.items[1], "world");

    const idv = ctx.queryValues("id") catch return try std.testing.expect(false);
    defer idv.deinit();
    try std.testing.expectEqualStrings(idv.items[0], "1234");

    const messages = ctx.queryArray("message") catch return try std.testing.expect(false);
    try std.testing.expectEqualStrings(messages[0], "hello");
    try std.testing.expectEqualStrings(messages[1], "world");

    var ids: std.StringHashMap(std.ArrayList([]const u8)) = ctx.queryMap("ids") orelse return try std.testing.expect(false);
    defer ids.deinit();
    try std.testing.expectEqualStrings(ids.get("a").?.items[0], "1234");
    try std.testing.expectEqualStrings(ids.get("b").?.items[0], "hello");
    try std.testing.expectEqualStrings(ids.get("b").?.items[1], "world");
}

test "context query map" {
    const allocator = std.testing.allocator;

    var req = Request.init(.{
        .target = "/query?ids[a]=1234&ids[b]=hello&ids[b]=world",
        .allocator = allocator,
    });
    var ctx = try Context.init(.{ .request = &req, .allocator = allocator });
    defer ctx.destroy();

    var ids: std.StringHashMap(std.ArrayList([]const u8)) = ctx.queryMap("ids") orelse return try std.testing.expect(false);
    defer ids.deinit();

    try std.testing.expectEqualStrings(ids.get("a").?.items[0], "1234");
    try std.testing.expectEqualStrings(ids.get("b").?.items[0], "hello");
    try std.testing.expectEqualStrings(ids.get("b").?.items[1], "world");
}
