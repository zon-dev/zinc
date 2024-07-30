const std = @import("std");
const http = std.http;
const Header = http.Header;

pub const Response = @This();

// http_version:http.Version = std.http.Version.@"HTTP/1.1",
version:[]const u8 = "HTTP/1.1",
status: http.Status = http.Status.ok,
body: []const u8 = "",
content_type: []const u8 = "text/html",
charset:[]const u8 = "utf-8",

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
    const allocator = std.heap.page_allocator;
    const body = self.body;

    var res = std.ArrayList(u8).init(allocator);
    defer allocator.free(res.items);

    const content_length = try std.fmt.allocPrint(allocator,"Content-Length: {}\r\n", .{body.len});
    defer allocator.free(content_length);

    // const protocal =  "HTTP/1.1 200";
    const protocal = try std.fmt.allocPrint(allocator,"{s} {d}",.{self.version, @intFromEnum(self.status)});
    defer allocator.free(protocal);
    try res.appendSlice(protocal);
    try res.appendSlice("\r\n");

    const content_type = try std.fmt.allocPrint(allocator,"Content-Type: {s}; charset={s}", .{self.content_type, self.charset});
    defer allocator.free(content_type);

    try res.appendSlice(content_type);
    try res.appendSlice("\r\n");
    try res.appendSlice(content_length);
    try res.appendSlice("\r\n");
    try res.appendSlice(body);
    return try res.toOwnedSlice();
}

// pub fn hello() []const u8 {
//     const body = "Hello World!";
//     const protocal = "HTTP/1.1 200 HELLO WORLD\r\n";
//     const content_type = "Content-Type: text/html; charset=utf8\r\n";
//     const line = "\r\n";
//     const body_len = std.fmt.comptimePrint("{}", .{body.len});
//     const content_length = "Content-Length: " ++ body_len ++ "\r\n";
//     const result =
//         protocal ++
//         content_type ++
//         content_length ++
//         line ++
//         body;
//     return result;
// }