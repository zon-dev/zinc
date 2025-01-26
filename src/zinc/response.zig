const std = @import("std");
const http = std.http;
const Status = http.Status;

const RespondOptions = std.http.Server.Request.RespondOptions;

const Config = @import("config.zig").Config;

pub const Response = @This();
const Self = @This();

const zinc = @import("../zinc.zig");
const IO = zinc.AIO.IO;

allocator: std.mem.Allocator,
// conn: std.net.Stream = undefined,
conn: std.posix.socket_t = undefined,

// TODO
// io: *IO = undefined,
completion: IO.Completion = undefined,

req_method: ?http.Method = undefined,

version: []const u8 = "HTTP/1.1",
status: std.http.Status = .ok,
header: std.ArrayList(std.http.Header) = undefined,

body: ?[]const u8 = null,

body_buffer_len: usize = 1024,

pub fn init(self: Self) anyerror!*Response {
    const response = try self.allocator.create(Response);
    response.* = .{
        .allocator = self.allocator,
        .header = std.ArrayList(std.http.Header).init(self.allocator),
        .conn = self.conn,
        // .io = self.io,
    };
    return response;
}

pub fn deinit(self: *Self) void {
    if (self.body != null) {
        self.allocator.free(self.body.?);
    }
    self.header.deinit();

    self.allocator.destroy(self);
}
pub fn send(self: *Self, content: []const u8, options: RespondOptions) anyerror!void {
    const req_method = self.req_method.?;

    const transfer_encoding_none = (options.transfer_encoding orelse .chunked) == .none;
    const keep_alive = !transfer_encoding_none and options.keep_alive;
    const phrase = options.reason orelse options.status.phrase() orelse "";

    var first_buffer: [500]u8 = undefined;
    var h = std.ArrayListUnmanaged(u8).initBuffer(&first_buffer);

    h.fixedWriter().print("{s} {d} {s}\r\n", .{
        @tagName(options.version), @intFromEnum(options.status), phrase,
    }) catch unreachable;

    switch (options.version) {
        .@"HTTP/1.0" => if (keep_alive) h.appendSliceAssumeCapacity("connection: keep-alive\r\n"),
        .@"HTTP/1.1" => if (!keep_alive) h.appendSliceAssumeCapacity("connection: close\r\n"),
    }

    if (options.transfer_encoding) |transfer_encoding| switch (transfer_encoding) {
        .none => {},
        .chunked => h.appendSliceAssumeCapacity("transfer-encoding: chunked\r\n"),
    } else {
        h.fixedWriter().print("content-length: {d}\r\n", .{content.len}) catch unreachable;
    }

    var chunk_header_buffer: [18]u8 = undefined;
    const max_extra_headers = 25;
    var iovecs: [max_extra_headers * 4 + 3]std.posix.iovec_const = undefined;
    var iovecs_len: usize = 0;

    iovecs[iovecs_len] = .{
        .base = h.items.ptr,
        .len = h.items.len,
    };
    iovecs_len += 1;

    for (options.extra_headers) |header| {
        iovecs[iovecs_len] = .{
            .base = header.name.ptr,
            .len = header.name.len,
        };
        iovecs_len += 1;

        iovecs[iovecs_len] = .{
            .base = ": ",
            .len = 2,
        };
        iovecs_len += 1;

        if (header.value.len != 0) {
            iovecs[iovecs_len] = .{
                .base = header.value.ptr,
                .len = header.value.len,
            };
            iovecs_len += 1;
        }

        iovecs[iovecs_len] = .{
            .base = "\r\n",
            .len = 2,
        };
        iovecs_len += 1;
    }

    iovecs[iovecs_len] = .{
        .base = "\r\n",
        .len = 2,
    };
    iovecs_len += 1;

    if (req_method != .HEAD) {
        const is_chunked = (options.transfer_encoding orelse .none) == .chunked;
        if (is_chunked) {
            if (content.len > 0) {
                const chunk_header = std.fmt.bufPrint(
                    &chunk_header_buffer,
                    "{x}\r\n",
                    .{content.len},
                ) catch unreachable;

                iovecs[iovecs_len] = .{
                    .base = chunk_header.ptr,
                    .len = chunk_header.len,
                };
                iovecs_len += 1;

                iovecs[iovecs_len] = .{
                    .base = content.ptr,
                    .len = content.len,
                };
                iovecs_len += 1;

                iovecs[iovecs_len] = .{
                    .base = "\r\n",
                    .len = 2,
                };
                iovecs_len += 1;
            }

            iovecs[iovecs_len] = .{
                .base = "0\r\n\r\n",
                .len = 5,
            };
            iovecs_len += 1;
        } else if (content.len > 0) {
            iovecs[iovecs_len] = .{
                .base = content.ptr,
                .len = content.len,
            };
            iovecs_len += 1;
        }
    }
    // try self.conn.write(iovecs[0..iovecs_len]);
    _ = try std.posix.writev(self.conn, iovecs[0..iovecs_len]);
}

pub fn write(self: *Self, content: []const u8, options: RespondOptions) anyerror!void {
    const req_method = self.req_method.?;

    const transfer_encoding_none = (options.transfer_encoding orelse .chunked) == .none;
    const keep_alive = !transfer_encoding_none and options.keep_alive;
    const phrase = options.reason orelse options.status.phrase() orelse "";

    var first_buffer: [500]u8 = undefined;
    var h = std.ArrayListUnmanaged(u8).initBuffer(&first_buffer);
    // if (request.head.expect != null) {
    //     // reader() and hence discardBody() above sets expect to null if it
    //     // is handled. So the fact that it is not null here means unhandled.
    //     h.appendSliceAssumeCapacity("HTTP/1.1 417 Expectation Failed\r\n");
    //     if (!keep_alive) h.appendSliceAssumeCapacity("connection: close\r\n");
    //     h.appendSliceAssumeCapacity("content-length: 0\r\n\r\n");
    //     try request.server.connection.stream.writeAll(h.items);
    //     return;
    // }

    h.fixedWriter().print("{s} {d} {s}\r\n", .{
        @tagName(options.version), @intFromEnum(options.status), phrase,
    }) catch unreachable;

    switch (options.version) {
        .@"HTTP/1.0" => if (keep_alive) h.appendSliceAssumeCapacity("connection: keep-alive\r\n"),
        .@"HTTP/1.1" => if (!keep_alive) h.appendSliceAssumeCapacity("connection: close\r\n"),
    }

    if (options.transfer_encoding) |transfer_encoding| switch (transfer_encoding) {
        .none => {},
        .chunked => h.appendSliceAssumeCapacity("transfer-encoding: chunked\r\n"),
    } else {
        h.fixedWriter().print("content-length: {d}\r\n", .{content.len}) catch unreachable;
    }

    var chunk_header_buffer: [18]u8 = undefined;
    const max_extra_headers = 25;
    var iovecs: [max_extra_headers * 4 + 3]std.posix.iovec_const = undefined;
    var iovecs_len: usize = 0;

    iovecs[iovecs_len] = .{
        .base = h.items.ptr,
        .len = h.items.len,
    };
    iovecs_len += 1;

    for (options.extra_headers) |header| {
        iovecs[iovecs_len] = .{
            .base = header.name.ptr,
            .len = header.name.len,
        };
        iovecs_len += 1;

        iovecs[iovecs_len] = .{
            .base = ": ",
            .len = 2,
        };
        iovecs_len += 1;

        if (header.value.len != 0) {
            iovecs[iovecs_len] = .{
                .base = header.value.ptr,
                .len = header.value.len,
            };
            iovecs_len += 1;
        }

        iovecs[iovecs_len] = .{
            .base = "\r\n",
            .len = 2,
        };
        iovecs_len += 1;
    }

    iovecs[iovecs_len] = .{
        .base = "\r\n",
        .len = 2,
    };
    iovecs_len += 1;

    if (req_method != .HEAD) {
        const is_chunked = (options.transfer_encoding orelse .none) == .chunked;
        if (is_chunked) {
            if (content.len > 0) {
                const chunk_header = std.fmt.bufPrint(
                    &chunk_header_buffer,
                    "{x}\r\n",
                    .{content.len},
                ) catch unreachable;

                iovecs[iovecs_len] = .{
                    .base = chunk_header.ptr,
                    .len = chunk_header.len,
                };
                iovecs_len += 1;

                iovecs[iovecs_len] = .{
                    .base = content.ptr,
                    .len = content.len,
                };
                iovecs_len += 1;

                iovecs[iovecs_len] = .{
                    .base = "\r\n",
                    .len = 2,
                };
                iovecs_len += 1;
            }

            iovecs[iovecs_len] = .{
                .base = "0\r\n\r\n",
                .len = 5,
            };
            iovecs_len += 1;
        } else if (content.len > 0) {
            iovecs[iovecs_len] = .{
                .base = content.ptr,
                .len = content.len,
            };
            iovecs_len += 1;
        }
    }
    // try self.conn.write(iovecs[0..iovecs_len]);
    _ = try std.posix.writev(self.conn, iovecs[0..iovecs_len]);
}

pub fn setStatus(self: *Self, status: std.http.Status) void {
    self.status = status;
}

pub fn setHeader(self: *Self, key: []const u8, value: []const u8) anyerror!void {
    try self.header.append(.{ .name = key, .value = value });
}

pub fn getHeaders(self: *Self) []std.http.Header {
    return self.header.items;
}

pub fn isKeepAlive(self: *Self) bool {
    for (self.header.items) |header| {
        // If the connection header is set to close, then the connection should be closed.
        if (std.ascii.eqlIgnoreCase(header.name, "Connection") and std.ascii.eqlIgnoreCase(header.value, "close")) {
            return false;
        }
    }

    return true;
}

pub fn setBody(self: *Self, body: []const u8) anyerror!void {
    var new_body = std.ArrayList(u8).init(self.allocator);
    defer self.allocator.free(new_body.items);

    if (self.body) |old_body| {
        defer self.allocator.free(old_body);
        try new_body.appendSlice(old_body);
    }

    try new_body.appendSlice(body);
    const slice = try new_body.toOwnedSlice();
    self.body = slice;
}

pub fn sendStatus(self: *Self, status: Status) anyerror!void {
    self.status = status;
    const body = self.body orelse "";
    return try self.send(body, .{
        .status = self.status,
        .extra_headers = self.header.items,
    });
}
