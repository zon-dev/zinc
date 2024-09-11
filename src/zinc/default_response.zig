const std = @import("std");
const net = std.net;

/// Response server error 405
pub fn methodNotAllowed(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/html\r\n\r\n<h1>Method Not Allowed</h1>");
}

/// Response not found 404
pub fn notFound(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\n\r\n<h1>Not Found</h1>");
}

/// Response server error 500
pub fn internalServerError(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n<h1>Internal Server Error</h1>");
}

/// Response server error 431
pub fn requestHeaderFieldsTooLarge(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Type: text/html\r\n\r\n<h1>Request Header Fields Too Large</h1>");
}

/// Response head 200
pub fn resHead(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 200 OK\r\n\r\n");
}

pub fn badRequest(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\n\r\n<h1>Bad Request</h1>");
}
