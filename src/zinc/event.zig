const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;
const utils = @import("utils.zig");

const Connection = @import("aio.zig").Connection;

const Event = union(enum) {
    accept: void,
    shutdown: void,

    recv: *Connection,
};
