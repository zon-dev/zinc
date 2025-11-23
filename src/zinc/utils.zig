const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const posix = std.posix;

const conn_mode = enum {
    IO_Uring,
    KQueue,
    EPoll,
};

pub fn connMode() conn_mode {
    if (builtin.os.tag.isBSD()) return conn_mode.KQueue;

    if (builtin.os.tag == .linux) return conn_mode.IO_Uring;

    return conn_mode.EPoll;
}

pub fn response(status: std.http.Status, conn: std.posix.socket_t) anyerror!void {
    var text: []const u8 = undefined;
    switch (status) {
        .ok => {
            text = "HTTP/1.1 200 OK\r\n";
        },
        .bad_request => {
            text = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\n\r\n<h1>Bad Request</h1>";
        },
        .not_found => {
            text = "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\n\r\n<h1>Not Found</h1>";
        },
        .method_not_allowed => {
            text = "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/html\r\n\r\n<h1>Method Not Allowed</h1>";
        },
        .request_header_fields_too_large => {
            text = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Type: text/html\r\n\r\n<h1>Request Header Fields Too Large</h1>";
        },
        .internal_server_error => {
            text = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n<h1>Internal Server Error</h1>\r\n -------- \r\n";
        },
        else => {
            text = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n<h1>Internal Server Error</h1>";
        },
    }

    _ = try std.posix.write(conn, text);
    // defer std.posix.close(conn);
}
