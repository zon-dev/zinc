const std = @import("std");
const net = std.net;

/// Response server error 405
pub fn methodNotAllowed(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\nContent-Type: text/html\r\n\r\n<h1>Method Not Allowed</h1>");
    defer conn.close();
}

/// Response not found 404
pub fn notFound(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Type: text/html\r\n\r\n<h1>Not Found</h1>");
    defer conn.close();
}

/// Response server error 500
pub fn internalServerError(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\nContent-Type: text/html\r\n\r\n<h1>Internal Server Error</h1>");
    defer conn.close();
}

/// Response server error 431
pub fn requestHeaderFieldsTooLarge(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: closed\r\nContent-Type: text/html\r\n\r\n<h1>Request Header Fields Too Large</h1>");
    defer conn.close();
}

/// Response head 200
pub fn resHead(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 200 OK\r\n\r\n");
    defer conn.close();
}

pub fn badRequest(conn: net.Stream) anyerror!void {
    _ = try conn.write("HTTP/1.1 400 Bad Request\r\nContent-Type: text/html\r\n\r\n<h1>Bad Request</h1>");
    defer conn.close();
}
