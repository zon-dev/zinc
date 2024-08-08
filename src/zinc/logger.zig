const std = @import("std");
const print = std.debug.print;

pub const Self = @This();

pub const level = enum {
    Debug,
    Info,
    Warn,
    Error,
};

level: level = level.Info,

prefix: []const u8 = "",

pub fn init(self: Self) Self {
    return .{
        .level = self.level,
        .prefix = self.prefix,
    };
}

pub fn debug(self: *Self, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(self.level) <= @intFromEnum(level.Debug)) {
        print("{s}", .{self.prefix});
        // print(fmt, args);
        _ = fmt;
        _ = args;
    }
}

pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(self.level) <= @intFromEnum(level.Info)) {
        print("{s}", .{self.prefix});
        print(fmt, args);
    }
}

pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(self.level) <= @intFromEnum(level.Warn)) {
        std.log.warn("{s}", .{self.prefix});
        std.log.warn(fmt, args);
    }
}
