//! Socket/fd syscall wrappers that `std.posix` provided before Zig 0.17.
//!
//! Zig 0.17 moved blocking I/O behind `std.Io` and deleted the thin
//! errno-mapping helpers (`posix.socket`, `posix.close`, `posix.accept`, ...).
//! The raw syscalls in `std.posix.system` are unchanged, so these wrappers
//! restore the old surface for the parts of the engine that manage their own
//! file descriptors and cannot go through a `std.Io` instance.
//!
//! Signatures and error sets intentionally match the pre-0.17 `std` versions so
//! call sites need no changes beyond the import.

const std = @import("std");
const posix = std.posix;
const system = posix.system;
const errno = posix.errno;
const unexpectedErrno = posix.unexpectedErrno;

pub const fd_t = posix.fd_t;
pub const socket_t = posix.socket_t;
pub const sockaddr = posix.sockaddr;
pub const socklen_t = posix.socklen_t;
pub const iovec_const = posix.iovec_const;

pub const SocketError = error{
    PermissionDenied,
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
} || posix.UnexpectedError;

/// Whether `SOCK.CLOEXEC`/`SOCK.NONBLOCK` may be OR-ed into `socket()`'s type
/// argument. That is a Linux extension some BSDs adopted; Darwin rejects it with
/// `EPROTOTYPE`, so there the bits are applied with `fcntl` after the fact.
const sock_flags_in_type = switch (@import("builtin").os.tag) {
    .linux, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!socket_t {
    const extra_flags = socket_type & (posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);
    const filtered_type = if (sock_flags_in_type) socket_type else socket_type & ~extra_flags;

    const rc = system.socket(@intCast(domain), @intCast(filtered_type), @intCast(protocol));
    if (rc >= 0) {
        if (!sock_flags_in_type and extra_flags != 0) applyDescriptorFlags(rc, extra_flags);
        return rc;
    }
    return switch (errno(rc)) {
        .ACCES => error.PermissionDenied,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .INVAL => error.ProtocolFamilyNotAvailable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        .PROTOTYPE => error.SocketTypeNotSupported,
        else => |err| unexpectedErrno(err),
    };
}

/// Closes a file descriptor. Close errors are unrecoverable and therefore
/// ignored, matching the old `std.posix.close`.
pub fn close(fd: fd_t) void {
    _ = system.close(fd);
}

pub const BindError = error{
    AccessDenied,
    AddressInUse,
    AlreadyBound,
    AddressFamilyNotSupported,
    AddressNotAvailable,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    ReadOnlyFileSystem,
    FileDescriptorNotASocket,
} || posix.UnexpectedError;

pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) BindError!void {
    const rc = system.bind(sock, addr, len);
    if (rc == 0) return;
    return switch (errno(rc)) {
        .ACCES, .PERM => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .INVAL => error.AlreadyBound,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .BADF => unreachable,
        .NOTSOCK => error.FileDescriptorNotASocket,
        .FAULT => unreachable,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOTDIR => error.NotDir,
        .ROFS => error.ReadOnlyFileSystem,
        else => |err| unexpectedErrno(err),
    };
}

pub const ListenError = error{
    AddressInUse,
    FileDescriptorNotASocket,
    OperationNotSupported,
    SystemResources,
} || posix.UnexpectedError;

pub fn listen(sock: socket_t, backlog: u31) ListenError!void {
    const rc = system.listen(sock, backlog);
    if (rc == 0) return;
    return switch (errno(rc)) {
        .ADDRINUSE => error.AddressInUse,
        .BADF => unreachable,
        .NOTSOCK => error.FileDescriptorNotASocket,
        .OPNOTSUPP => error.OperationNotSupported,
        else => |err| unexpectedErrno(err),
    };
}

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    FileDescriptorNotASocket,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketNotListening,
    OperationNotSupported,
    ProtocolFailure,
    BlockedByFirewall,
    ConnectionResetByPeer,
} || posix.UnexpectedError;

/// `flags` accepts `SOCK.CLOEXEC` and `SOCK.NONBLOCK`, as the old
/// `std.posix.accept` did.
pub fn accept(
    sock: socket_t,
    addr: ?*sockaddr,
    addr_size: ?*socklen_t,
    flags: u32,
) AcceptError!socket_t {
    while (true) {
        const rc = system.accept(sock, addr, addr_size);
        if (rc >= 0) {
            if (flags != 0) applyDescriptorFlags(rc, flags);
            return rc;
        }
        return switch (errno(rc)) {
            .INTR => continue,
            .AGAIN => error.WouldBlock,
            .BADF => unreachable,
            .CONNABORTED => error.ConnectionAborted,
            .FAULT => unreachable,
            .INVAL => error.SocketNotListening,
            .NOTSOCK => error.FileDescriptorNotASocket,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => error.SystemResources,
            .OPNOTSUPP => error.OperationNotSupported,
            .PROTO => error.ProtocolFailure,
            .PERM => error.BlockedByFirewall,
            .CONNRESET => error.ConnectionResetByPeer,
            else => |err| unexpectedErrno(err),
        };
    }
}

pub const ConnectError = error{
    PermissionDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    WouldBlock,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    AlreadyConnected,
    NetworkUnreachable,
    ConnectionTimedOut,
    FileNotFound,
    SystemResources,
} || posix.UnexpectedError;

pub fn connect(sock: socket_t, addr: *const sockaddr, len: socklen_t) ConnectError!void {
    while (true) {
        const rc = system.connect(sock, addr, len);
        if (rc == 0) return;
        return switch (errno(rc)) {
            .INTR => continue,
            .ACCES, .PERM => error.PermissionDenied,
            .ADDRINUSE => error.AddressInUse,
            .ADDRNOTAVAIL => error.AddressNotAvailable,
            .AFNOSUPPORT => error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => error.WouldBlock,
            .ALREADY => error.ConnectionPending,
            .BADF => unreachable,
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET => error.ConnectionResetByPeer,
            .FAULT => unreachable,
            .ISCONN => error.AlreadyConnected,
            .HOSTUNREACH, .NETUNREACH => error.NetworkUnreachable,
            .NOTSOCK => unreachable,
            .PROTOTYPE => unreachable,
            .TIMEDOUT => error.ConnectionTimedOut,
            .NOENT => error.FileNotFound,
            .NOBUFS, .NOMEM => error.SystemResources,
            else => |err| unexpectedErrno(err),
        };
    }
}

pub const WriteError = error{
    WouldBlock,
    NotOpenForWriting,
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    BrokenPipe,
    ConnectionResetByPeer,
    AccessDenied,
} || posix.UnexpectedError;

pub const ReadError = error{
    WouldBlock,
    NotOpenForReading,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    InputOutput,
    SystemResources,
    BrokenPipe,
} || posix.UnexpectedError;

pub fn read(fd: fd_t, buffer: []u8) ReadError!usize {
    while (true) {
        const rc = system.read(fd, buffer.ptr, buffer.len);
        if (rc >= 0) return @intCast(rc);
        return switch (errno(rc)) {
            .INTR => continue,
            .INVAL, .FAULT => unreachable,
            .AGAIN => error.WouldBlock,
            .BADF => error.NotOpenForReading,
            .CONNRESET => error.ConnectionResetByPeer,
            .TIMEDOUT => error.ConnectionTimedOut,
            .IO => error.InputOutput,
            .NOBUFS, .NOMEM => error.SystemResources,
            .PIPE => error.BrokenPipe,
            else => |err| unexpectedErrno(err),
        };
    }
}

pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    while (true) {
        const rc = system.write(fd, bytes.ptr, bytes.len);
        if (rc >= 0) return @intCast(rc);
        return switch (errno(rc)) {
            .INTR => continue,
            .INVAL, .FAULT => unreachable,
            .AGAIN => error.WouldBlock,
            .BADF => error.NotOpenForWriting,
            .DQUOT => error.DiskQuota,
            .FBIG => error.FileTooBig,
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .PERM => error.AccessDenied,
            .PIPE => error.BrokenPipe,
            .CONNRESET => error.ConnectionResetByPeer,
            .BUSY => error.DeviceBusy,
            else => |err| unexpectedErrno(err),
        };
    }
}

pub fn writev(fd: fd_t, iov: []const iovec_const) WriteError!usize {
    while (true) {
        const rc = system.writev(fd, iov.ptr, @intCast(iov.len));
        if (rc >= 0) return @intCast(rc);
        return switch (errno(rc)) {
            .INTR => continue,
            .INVAL, .FAULT => unreachable,
            .AGAIN => error.WouldBlock,
            .BADF => error.NotOpenForWriting,
            .DQUOT => error.DiskQuota,
            .FBIG => error.FileTooBig,
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .PERM => error.AccessDenied,
            .PIPE => error.BrokenPipe,
            .CONNRESET => error.ConnectionResetByPeer,
            .BUSY => error.DeviceBusy,
            else => |err| unexpectedErrno(err),
        };
    }
}

pub const GetSockNameError = error{
    SystemResources,
    FileDescriptorNotASocket,
} || posix.UnexpectedError;

pub fn getsockname(sock: socket_t, addr: *sockaddr, addrlen: *socklen_t) GetSockNameError!void {
    const rc = system.getsockname(sock, addr, addrlen);
    if (rc == 0) return;
    return switch (errno(rc)) {
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOTSOCK => error.FileDescriptorNotASocket,
        .NOBUFS => error.SystemResources,
        else => |err| unexpectedErrno(err),
    };
}

/// Applies `SOCK.CLOEXEC`/`SOCK.NONBLOCK` to an existing descriptor, for platforms
/// that accept neither `accept4()` nor those bits in `socket()`'s type argument.
/// Failures leave the descriptor usable with default flags, so they are ignored
/// rather than failing the caller.
fn applyDescriptorFlags(fd: socket_t, flags: u32) void {
    if (flags & posix.SOCK.CLOEXEC != 0) {
        const cur = system.fcntl(fd, posix.F.GETFD, @as(c_int, 0));
        if (cur != -1) {
            _ = system.fcntl(fd, posix.F.SETFD, cur | @as(c_int, posix.FD_CLOEXEC));
        }
    }
    if (flags & posix.SOCK.NONBLOCK != 0) {
        const nonblock: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
        const cur = system.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
        if (cur != -1) {
            _ = system.fcntl(fd, posix.F.SETFL, cur | nonblock);
        }
    }
}
