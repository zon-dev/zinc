const std = @import("std");

const zinc = @import("../zinc.zig");
const Context = zinc.Context;

// pub const Handler = @This();
// const Self = @This();

/// HandlerFn is a function pointer that takes a Context and returns an error.
pub const HandlerFn = *const fn (*Context) anyerror!void;
