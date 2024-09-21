const std = @import("std");
const net = std.net;

pub fn response(status: std.http.Status, conn: net.Stream) anyerror!void {
    const text: []const u8 = undefined;
    switch (status) {
        .ok => {
            text = "HTTP/1.1 200 OK\r\nConnection: close\r\n";
        },
        .bad_request => {
            text = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Type: text/html\r\n\r\n<h1>Bad Request</h1>";
        },
        .not_found => {
            text = "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Type: text/html\r\n\r\n<h1>Not Found</h1>";
        },
        .method_not_allowed => {
            text = "HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\nContent-Type: text/html\r\n\r\n<h1>Method Not Allowed</h1>";
        },
        .request_header_fields_too_large => {
            text = "HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: closed\r\nContent-Type: text/html\r\n\r\n<h1>Request Header Fields Too Large</h1>";
        },
        .internal_server_error => {
            text = "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\nContent-Type: text/html\r\n\r\n<h1>Internal Server Error</h1>";
        },

        else => {
            text = "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\nContent-Type: text/html\r\n\r\n<h1>Internal Server Error</h1>";
        },
    }
    _ = try conn.write(text);
    defer conn.close();
}
