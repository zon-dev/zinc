const std = @import("std");
const Header = std.http.Header;

allocator: std.mem.Allocator = std.heap.page_allocator,
headers: std.ArrayList(Header),

pub const Headers = @This();

pub fn init() Headers {
    return Headers{
        .headers = std.ArrayList(Header).init(std.heap.page_allocator),
    };
}

pub fn add(self: *Headers, comptime name: []const u8, comptime value: []const u8) anyerror!void {
    const header = .{ .name = name, .value = value };
    try self.headers.append(header);
}

pub fn get(self: *Headers, comptime name: []const u8) ?Header {
    const headers = self.headers.items;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return header;
        }
    }
    return null;
}

pub fn getHeaders(self: *Headers) []Header {
    return self.headers.items;
}

pub fn set(self: *Headers, comptime name: []const u8, comptime value: []const u8) anyerror!void {
    if (self.get(name) != null) {
        try self.remove(name);
    }
    try self.add(name, value);
}

pub fn remove(self: *Headers, comptime name: []const u8) anyerror!void {
    const headers = self.headers.items;
    for (headers, 0..) |header, index| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            _ = self.headers.orderedRemove(index);
            return;
        }
    }
}

pub fn clear(self: *Headers) void {
    self.headers.clearAndFree();
}

pub fn deinit(self: *Headers) void {
    self.headers.deinit();
}

pub fn len(self: *Headers) usize {
    return self.headers.items.len;
}

pub fn capacity(self: *Headers) usize {
    return self.headers.capacity;
}

pub fn items(self: *Headers) []Header {
    return self.headers.items;
}
