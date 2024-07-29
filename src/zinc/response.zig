const std = @import("std");
const http = std.http;
const Header = http.Header;

pub const Response = struct {
    // status: u16,
    // headers: []const u8,
    // body: []const u8,

    // The content type. Use header("content-type", value) for a content type.
    content_type: ?[]const u8 = "text/html",

    // pub fn set_body(body: []const u8) anyerror!void {
    //     _ = body;
    //     // return void;
    // }
    pub fn sendBody(self: @This(), body: []const u8) anyerror!void {
        _ = self;
        // _ = body;
        std.debug.print("body: {s}\n", .{body});
    }

    pub fn json(self: *Response, value: anytype, options: std.json.StringifyOptions) !void {
        // try std.json.stringify(value, options, Writer.init(self));
        // _ = self;
        _ = value;
        _ = options;

        self.content_type = "application/json";
    }
};
