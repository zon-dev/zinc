const std = @import("std");
const mem = std.mem;
const posix = std.posix;

const ProcessPool = struct {
    index: usize,
    batch_size: usize,

    threads: []std.Thread,
    arena: std.heap.ArenaAllocator,

    event: posix.Kevent,

    const Self = @This();

    pub fn detach(self: *ProcessPool) !void {
        _ = self;
    }
    pub fn spawn(self: *Self, args: anytype) void {
        _ = self;
        _ = args;

    }

    pub fn flush(self: *Self, batch_size: usize) void {
        _ = self;
        _ = batch_size;
    }
};
