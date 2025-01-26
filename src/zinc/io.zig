const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const os = std.os;
const posix = std.posix;
const linux = os.linux;
const IoUring = linux.IoUring;
const io_uring_cqe = linux.io_uring_cqe;
const io_uring_sqe = linux.io_uring_sqe;
const log = std.log.scoped(.io);

const assert = std.debug.assert;

const utils = @import("utils.zig");

pub const IO = switch (builtin.target.os.tag) {
    .linux => IO_Uring,
    .macos, .tvos, .watchos, .ios => Kqueue,
    else => @compileError("IO is not supported for platform"),
};

/// Used to send/receive messages to/from a client or fellow replica.
pub const Connection = struct {
    state: enum {
        /// The connection is not in use, with peer set to `.none`.
        free,
        /// The connection has been reserved for an in progress accept operation,
        /// with peer set to `.none`.
        accepting,
        /// The peer is a replica and a connect operation has been started
        /// but not yet completed.
        connecting,
        /// The peer is fully connected and may be a client, replica, or unknown.
        connected,

        /// The connection is read
        read,

        ///
        write,

        /// The connection is being terminated but cleanup has not yet finished.
        terminating,
    } = .free,

    event: posix.Kevent = undefined,

    fd: posix.socket_t = -1,
    pub fn init(self: Connection) Connection {
        return .{ .state = self.state, .fd = self.fd };
    }

    pub fn getSocket(self: Connection) posix.socket_t {
        return self.fd;
    }
};

pub const Event = union(enum) {
    read: void,
    write: void,
    signal: void,

    accept: void,
    shutdown: void,

    recv: *Connection,
};

pub const Kqueue = struct {
    fd: posix.fd_t,

    changed: usize = 0,

    events: [MAX_EVENTS]posix.Kevent = undefined,

    change_buffer: [CHANGE_BUFFER]posix.Kevent = undefined,

    const MAX_EVENTS = 255;
    const CHANGE_BUFFER = 32;

    pub fn init(entries: u12, flags: u32) !Kqueue {
        _ = entries;
        _ = flags;
        const fd = try posix.kqueue();
        assert(fd > -1);
        return Kqueue{ .fd = fd };
    }

    pub fn deinit(self: *Kqueue) void {
        assert(self.fd > -1);
        posix.close(self.fd);
        self.fd = -1;
    }

    const Self = @This();
    const Kevent = posix.Kevent;

    fn start(self: *Self) !void {
        _ = self;
        return;
    }

    fn stop(self: *Self) void {
        // called from an arbitrary thread, can't use change
        _ = posix.kevent(self.fd, &.{
            .{
                .ident = 2,
                .filter = posix.system.EVFILT.USER,
                .flags = posix.system.EV.ADD | posix.system.EV.ONESHOT,
                .fflags = posix.system.NOTE.TRIGGER,
                .data = 0,
                .udata = 2,
            },
        }, &.{}, null) catch |err| {
            std.log.err("Failed to send stop signal: {}", .{err});
        };
    }

    pub fn signal(self: *Self) !void {
        // called from thread pool thread, cant queue these in self.changes
        _ = try posix.kevent(self.fd, &.{.{
            .ident = 1,
            .filter = posix.system.EVFILT.USER,
            .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
            .fflags = posix.system.NOTE.TRIGGER,
            .data = 0,
            .udata = 1,
        }}, &.{}, null);
    }

    pub fn monitorAccept(self: *Self, fd: posix.fd_t) !void {
        try self.change(fd, 0, posix.system.EVFILT.READ, posix.system.EV.ADD | posix.system.EV.ENABLE, 0);
    }

    fn pauseAccept(self: *Self, fd: posix.fd_t) !void {
        try self.change(fd, 0, posix.system.EVFILT.READ, posix.system.EV.DISABLE, 0);
    }

    pub fn monitorRead(self: *Self, conn: *Connection) !void {
        try self.change(conn.getSocket(), @intFromPtr(conn), posix.system.EVFILT.READ, posix.system.EV.ADD | posix.system.EV.ENABLE, 0);
    }

    pub fn monitorWrite(self: *Self, conn: *Connection) !void {
        try self.change(conn.getSocket(), @intFromPtr(conn), posix.system.EVFILT.WRITE, posix.system.EV.ADD | posix.system.EV.ENABLE, 0);
    }

    fn rearmRead(self: *Self, socket: posix.socket_t) !void {
        // called from the worker thread, can't use change_buffer
        _ = try posix.kevent(self.fd, &.{.{
            .ident = @intCast(socket),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(socket),
        }}, &.{}, null);
    }

    fn switchToOneShot(self: *Self, socket: posix.socket_t) !void {
        // From the Kqueue docs, you'd think you can just re-add the socket with EV.DISPATCH to enable
        // dispatching. But that _does not_ work on MacOS. Removing and Re-adding does.
        try self.change(socket, 0, posix.system.EVFILT.READ, posix.system.EV.DELETE, 0);
        try self.change(socket, @intCast(socket), posix.system.EVFILT.READ, posix.system.EV.ADD | posix.system.EV.DISPATCH, 0);
    }

    fn remove(self: *Self, socket: posix.socket_t) !void {
        try self.change(socket, 0, posix.system.EVFILT.READ, posix.system.EV.DELETE, 0);
    }

    fn change(self: *Self, fd: posix.fd_t, data: usize, filter: i16, flags: u16, fflags: u16) !void {
        var change_count = self.changed;
        var change_buffer = &self.change_buffer;

        if (change_count == change_buffer.len) {
            // calling this with an empty event_list will return immediate
            _ = try posix.kevent(self.fd, change_buffer, &.{}, null);
            change_count = 0;
        }
        change_buffer[change_count] = .{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = flags,
            .fflags = fflags,
            .data = 0,
            .udata = data,
        };
        self.changed = change_count + 1;
    }

    pub fn wait(self: *Self, timeout_sec: ?i32) !Iterator {
        const events = &self.events;
        const timeout: ?posix.timespec = if (timeout_sec) |ts| posix.timespec{ .sec = ts, .nsec = 0 } else null;
        const changed = try posix.kevent(self.fd, self.change_buffer[0..self.changed], events, if (timeout) |ts| &ts else null);

        // reset the change buffer
        self.changed = 0;

        return .{
            .index = 0,
            .io = self,
            .events = events[0..changed],
        };
    }
};

const Iterator = struct {
    io: *IO,
    index: usize,
    events: []posix.Kevent,

    pub fn next(self: *Iterator) ?Event {
        const index = self.index;
        const events = self.events;
        if (index == events.len) {
            return null;
        }

        const event = &self.events[index];
        self.index = index + 1;
        switch (event.udata) {
            0 => return .{ .accept = {} },
            1 => {
                // rearm it
                self.io.change(1, 1, posix.system.EVFILT.USER, posix.system.EV.ENABLE, posix.system.NOTE.FFNOP) catch |err| {
                    std.log.err("failed to rearm signal: {}", .{err});
                };
                return .{ .signal = {} };
            },
            2 => return .{ .shutdown = {} },
            else => |nptr| return .{ .recv = @ptrFromInt(nptr) },
        }
    }
};

pub const IO_Uring = struct {
    const Self = @This();

    ring: IoUring,

    pub fn init(entries: u12, flags: u32) !IO {
        // Detect the linux version to ensure that we support all io_uring ops used.
        const uts = posix.uname();
        const version = try parse_dirty_semver(&uts.release);
        if (version.order(std.SemanticVersion{ .major = 5, .minor = 5, .patch = 0 }) == .lt) {
            @panic("Linux kernel 5.5 or greater is required for io_uring OP_ACCEPT");
        }

        errdefer |err| switch (err) {
            error.SystemOutdated => {
                std.log.err("io_uring is not available", .{});
                std.log.err("likely cause: the syscall is disabled by seccomp", .{});
            },
            error.PermissionDenied => {
                std.log.err("io_uring is not available", .{});
                std.log.err("likely cause: the syscall is disabled by sysctl, " ++
                    "try 'sysctl -w kernel.io_uring_disabled=0'", .{});
            },
            else => {},
        };

        return IO{ .ring = try IoUring.init(entries, flags) };
    }

    pub fn deinit(self: *IO) void {
        self.ring.deinit();
    }

    pub fn wait(self: *Self, timeout_sec: ?i32) !Iterator {
        const events = &self.events;
        const timeout: ?posix.timespec = if (timeout_sec) |ts| posix.timespec{ .sec = ts, .nsec = 0 } else null;
        const changed = try posix.kevent(self.fd, self.change_buffer[0..self.changed], events, if (timeout) |ts| &ts else null);

        // reset the change buffer
        self.changed = 0;

        return .{
            .index = 0,
            .io = self,
            .events = events[0..changed],
        };
    }

    // std.SemanticVersion requires there be no extra characters after the
    // major/minor/patch numbers. But when we try to parse `uname
    // --kernel-release` (note: while Linux doesn't follow semantic
    // versioning, it doesn't violate it either), some distributions have
    // extra characters, such as this Fedora one: 6.3.8-100.fc37.x86_64, and
    // this WSL one has more than three dots:
    // 5.15.90.1-microsoft-standard-WSL2.
    pub fn parse_dirty_semver(dirty_release: []const u8) !std.SemanticVersion {
        const release = blk: {
            var last_valid_version_character_index: usize = 0;
            var dots_found: u8 = 0;
            for (dirty_release) |c| {
                if (c == '.') dots_found += 1;
                if (dots_found == 3) {
                    break;
                }

                if (c == '.' or (c >= '0' and c <= '9')) {
                    last_valid_version_character_index += 1;
                    continue;
                }

                break;
            }

            break :blk dirty_release[0..last_valid_version_character_index];
        };

        return std.SemanticVersion.parse(release);
    }
};
