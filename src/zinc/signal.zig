const std = @import("std");
const builtin = @import("builtin");

const zinc = @import("../zinc.zig");
const IO = zinc.IO.IO;

const os = std.os;
const assert = std.debug.assert;
const Atomic = std.atomic.Value;
const log = std.log.scoped(.zinc_signal);
// const log = std.log;

/// A Signal is a way to trigger a registered callback on a IO instance
/// when notification occurs from another thread.
/// It does this by using OS sockets (which are thread safe)
/// to resolve IO.Completions on the thread.
pub const Signal = struct {
    io: *IO,
    server_socket: std.posix.socket_t,
    accept_socket: std.posix.socket_t,
    connect_socket: std.posix.socket_t,

    completion: IO.Completion,
    recv_buffer: [1]u8,
    send_buffer: [1]u8,

    on_signal_fn: *const fn (*Signal) void,
    state: Atomic(enum(u8) {
        running,
        waiting,
        notified,
    }),

    pub fn init(self: *Signal, address: std.net.Address, handle: std.posix.socket_t, io: *IO, on_signal_fn: *const fn (*Signal) void) !void {
        self.io = io;
        self.server_socket = handle;

        self.connect_socket = self.io.open_socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM,
            std.posix.IPPROTO.TCP,
        ) catch |err| {
            log.err("failed to create signal connect socket: {}", .{err});
            return error.Unexpected;
        };
        errdefer self.io.close_socket(self.connect_socket);

        // Tracks when the connect_socket connects to the server_socket.
        const DoConnect = struct {
            result: IO.ConnectError!void = undefined,
            completion: IO.Completion = undefined,
            is_connected: bool = false,

            fn on_connect(
                do_connect: *@This(),
                _completion: *IO.Completion,
                result: IO.ConnectError!void,
            ) void {
                assert(&do_connect.completion == _completion);
                assert(!do_connect.is_connected);
                do_connect.is_connected = true;
                do_connect.result = result;
            }
        };

        var do_connect = DoConnect{};
        self.io.connect(
            *DoConnect,
            &do_connect,
            DoConnect.on_connect,
            &do_connect.completion,
            self.connect_socket,
            address,
        );

        // Wait for the connect_socket to connect to the server_socket.
        self.accept_socket = IO.INVALID_SOCKET;
        while (!do_connect.is_connected or self.accept_socket == IO.INVALID_SOCKET) {
            self.io.tick() catch |err| {
                log.err("failed to tick IO when setting up signal: {}", .{err});
                return error.Unexpected;
            };

            // Try to accept the connection from the connect_socket as the accept_socket.
            if (self.accept_socket == IO.INVALID_SOCKET) {
                self.accept_socket = std.posix.accept(
                    self.server_socket,
                    null,
                    null,
                    0,
                ) catch |e| switch (e) {
                    error.WouldBlock => continue,
                    error.ConnectionAborted => unreachable,
                    error.ConnectionResetByPeer => unreachable,
                    error.FileDescriptorNotASocket => unreachable,
                    error.ProcessFdQuotaExceeded,
                    error.SystemFdQuotaExceeded,
                    error.SystemResources,
                    => return error.SystemResources,
                    error.SocketNotListening => unreachable,
                    error.BlockedByFirewall => unreachable,
                    error.ProtocolFailure,
                    error.OperationNotSupported,
                    error.NetworkSubsystemFailed,
                    => return error.NetworkSubsystemFailed,
                    error.Unexpected => return error.Unexpected,
                };
            }
        }

        _ = do_connect.result catch |err| {
            log.err("failed to connect on signal client socket: {}", .{err});
            return error.Unexpected;
        };

        assert(do_connect.is_connected);
        assert(self.accept_socket != IO.INVALID_SOCKET);
        assert(self.connect_socket != IO.INVALID_SOCKET);

        self.completion = undefined;
        self.recv_buffer = undefined;
        self.send_buffer = undefined;

        self.state = @TypeOf(self.state).init(.running);
        self.on_signal_fn = on_signal_fn;
        self.wait();
    }

    pub fn deinit(self: *Signal) void {
        self.io.close_socket(self.server_socket);
        self.io.close_socket(self.accept_socket);
        self.io.close_socket(self.connect_socket);
    }

    /// Schedules the on_signal callback to be invoked on the IO thread.
    /// Safe to call from multiple threads.
    pub fn notify(self: *Signal) void {
        if (self.state.swap(.notified, .release) == .waiting) {
            self.wake();
        }
    }

    fn wake(self: *Signal) void {
        assert(self.accept_socket != IO.INVALID_SOCKET);
        self.send_buffer[0] = 0;

        // TODO: use std.posix.send() instead when it gets fixed for windows
        if (builtin.target.os.tag != .windows) {
            _ = std.posix.send(self.accept_socket, &self.send_buffer, 0) catch unreachable;
            return;
        }

        const buf: []const u8 = &self.send_buffer;
        const rc = os.windows.sendto(self.accept_socket, buf.ptr, buf.len, 0, null, 0);
        assert(rc != os.windows.ws2_32.SOCKET_ERROR);
    }

    fn wait(self: *Signal) void {
        const state = self.state.cmpxchgStrong(
            .running,
            .waiting,
            .acquire,
            .acquire,
        ) orelse return self.io.recv(
            *Signal,
            self,
            on_recv,
            &self.completion,
            self.connect_socket,
            &self.recv_buffer,
        );

        switch (state) {
            .running => unreachable, // Not possible due to CAS semantics.
            .waiting => unreachable, // We should be the only ones who could've started waiting.
            .notified => {}, // A thread woke us up before we started waiting so reschedule below.
        }

        self.io.timeout(
            *Signal,
            self,
            on_timeout,
            &self.completion,
            0, // zero-timeout functions as a yield.
        );
    }

    fn on_recv(
        self: *Signal,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        assert(completion == &self.completion);
        _ = result catch |err| std.debug.panic("Signal recv error: {}", .{err});
        self.on_signal();
    }

    fn on_timeout(
        self: *Signal,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        assert(completion == &self.completion);
        _ = result catch |err| std.debug.panic("Signal timeout error: {}", .{err});
        self.on_signal();
    }

    fn on_signal(self: *Signal) void {
        const state = self.state.cmpxchgStrong(
            .notified,
            .running,
            .acquire,
            .acquire,
        ) orelse {
            (self.on_signal_fn)(self);
            return self.wait();
        };

        switch (state) {
            .running => unreachable, // Multiple racing calls to on_signal().
            .waiting => unreachable, // on_signal() called without transitioning to a waking state.
            .notified => unreachable, // Not possible due to CAS semantics.
        }
    }
};
