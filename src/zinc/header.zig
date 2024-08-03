const std = @import("std");

pub const Header = @This();

name: []const u8,
value: []const u8,

pub fn init(comptime name: []const u8, comptime value: []const u8) Header {
    return Header{
        .name = name,
        .value = value,
    };
}

pub fn initEmpty() Header {
    return Header{
        .name = "",
        .value = "",
    };
}

pub fn set(self: *Header, comptime name: []const u8, comptime value: []const u8) void {
    self.name = name;
    self.value = value;
}

pub fn getName(self: *Header) []const u8 {
    return self.name;
}

pub fn getValue(self: *Header) []const u8 {
    return self.value;
}
