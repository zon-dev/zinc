const std = @import("std");
/// Param is a single URL parameter, consisting of a name and a value.
pub const Param = @This();
name: []const u8 = "",
value: []const u8 = "",
