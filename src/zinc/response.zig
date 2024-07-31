const std = @import("std");
const http = std.http;
const Header = http.Header;

pub const Response = @This();

// http_version:http.Version = std.http.Version.@"HTTP/1.1",
version:[]const u8 = "HTTP/1.1",
status: http.Status = http.Status.ok,
content_type: []const u8 = "text/html",
charset:[]const u8 = "utf-8",

body: []const u8 = "",

pub fn sendBody(_: Response, body: []const u8) anyerror!void {
    std.debug.print("body: {s}\n", .{ body });
}
pub fn json(self: *Response, value: anytype, options: std.json.StringifyOptions) !void {
    // try std.json.stringify(value, options, Writer.init(self));
    _ = value;
    _ = options;
    self.content_type = "application/json";
}

pub fn stringify(self: Response) ![]const u8 {
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
    const protocal = try std.fmt.allocPrint(allocator,"{s} {d}",.{self.version, @intFromEnum(self.status)});
    // const content_type = "Content-Type: text/html; charset=utf-8";
    const content_type = try std.fmt.allocPrint(allocator,"Content-Type: {s}; charset={s}", .{self.content_type, self.charset});
    const body = self.body;
    const content_length = try std.fmt.allocPrint(allocator,"Content-Length: {}\r\n", .{body.len});

    // Todo, 
    var res = std.ArrayList(u8).init(std.heap.page_allocator);
    try res.appendSlice(protocal);
    try res.appendSlice("\r\n");
    try res.appendSlice(content_type);
    try res.appendSlice("\r\n");
    try res.appendSlice(content_length);
    try res.appendSlice("\r\n");
    try res.appendSlice(body);
    return try res.toOwnedSlice();
}