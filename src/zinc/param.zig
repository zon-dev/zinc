const std = @import("std");
/// Param is a single URL parameter, consisting of a name and a value.
pub const Param = @This();
name: []const u8 = "",
value: []const u8 = "",

const page_allocator = std.heap.page_allocator;

pub const params: std.StringHashMap(u8) = std.StringHashMap(u8).init(page_allocator);
