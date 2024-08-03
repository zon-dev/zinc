const std = @import("std");
const http = std.http;
const header = http.Header;
const http_request = std.http.Server.Request;
const http_response = std.http.Server.Response;

const RespondOptions = http_request.RespondOptions;
const Config = @import("config.zig").Config;

pub const Response = @This();
const Self = @This();

request: *http_request,

version: []const u8 = "HTTP/1.1",
status: http.Status = http.Status.ok,
header: std.StringArrayHashMap([]u8) = std.StringArrayHashMap([]u8).init(std.heap.page_allocator),
body: []const u8 = "",

pub fn init(self: Self) Response {
    return Response{
        .request = self.request,
        .version = self.version,
        .status = self.status,
        .header = self.header,
        .body = self.body,
    };
}

pub fn send(self: *Self, content: []const u8, options: RespondOptions) http_response.WriteError!void {
    return try self.request.respond(content, options);
}

pub fn sendBody(self: *Self, content: []const u8) !void {
    try self.send(content, .{
        .keep_alive = false,
    });
}

pub fn stringify(self: *Self) ![]const u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("Memory leak!"); // check for memory leak
    }
    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // const protocal =  "HTTP/1.1 200";
    const protocal = try std.fmt.allocPrint(allocator, "{s} {d}", .{ self.version, @intFromEnum(self.status) });
    // const content_type = "Content-Type: text/html; charset=utf-8";
    const body = self.body;
    const content_length = try std.fmt.allocPrint(allocator, "Content-Length: {any}\r\n", .{body.len});
    var res = std.ArrayList(u8).init(std.heap.page_allocator);
    try res.appendSlice(protocal);
    try res.appendSlice("\r\n");
    // try res.appendSlice(content_type);
    // try res.appendSlice("\r\n");
    try res.appendSlice(content_length);
    try res.appendSlice("\r\n");
    try res.appendSlice(body);
    return try res.toOwnedSlice();
}
