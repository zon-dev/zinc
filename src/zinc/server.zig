const std = @import("std");
const posix = std.posix;
// const net_server = std.net.Server;

pub const ListenOptions = struct {
    /// How many connections the kernel will accept on the application's behalf.
    /// If more than this many connections pool in the kernel, clients will start
    /// seeing "Connection refused". The default is 1024.
    kernel_backlog: u31 = 1024,
    /// Sets SO_REUSEADDR and SO_REUSEPORT on POSIX.
    /// Sets SO_REUSEADDR on Windows, which is roughly equivalent.
    reuse_address: bool = false,
    /// Deprecated. Does the same thing as reuse_address.
    reuse_port: bool = false,

    /// For freebsd.
    reuse_port_lb: bool = false,

    force_nonblocking: bool = false,
};

/// The returned `Server` has an open `stream`.
pub fn listen(address: std.net.Address, options: ListenOptions) std.net.Address.ListenError!Server {
    const nonblock: u32 = if (options.force_nonblocking) posix.SOCK.NONBLOCK else 0;
    const posix_flags: u32 = posix.SOCK.CLOEXEC | nonblock;
    var sock_flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    sock_flags |= nonblock;

    const proto: u32 = if (address.any.family == posix.AF.UNIX) 0 else posix.IPPROTO.TCP;
    const sockfd = try posix.socket(address.any.family, sock_flags, proto);

    var s: Server = .{
        .flags = posix_flags,
        .listen_address = undefined,
        .stream = .{ .handle = sockfd },
    };
    errdefer s.stream.close();

    if (options.reuse_address or options.reuse_port or options.reuse_port_lb) {
        try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        if (@hasDecl(posix.SO, "REUSEPORT")) {
            try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
        }
        // For freebsd
        if (@hasDecl(posix.SO, "REUSEPORT_LB")) {
            try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
        }
    }

    try posix.bind(sockfd, &address.any, address.getOsSockLen());
    try posix.listen(sockfd, options.kernel_backlog);

    var socklen = address.getOsSockLen();
    try posix.getsockname(sockfd, &s.listen_address.any, &socklen);

    return s;
}

pub const Server = struct {
    // INVALID_SOCKET:usize = -1,
    // socket_client: posix.socket_t = -1,
    // socket_server: posix.socket_t = -1,
    // fd: posix.socket_t = IO.INVALID_SOCKET,

    listen_address: std.net.Address,
    stream: std.net.Stream,

    /// The following values can be bitwise ORed in flags to obtain different behavior:
    /// * `SOCK.NONBLOCK` - Set the `NONBLOCK` file status flag on the open file description (see `open`)
    ///   referred  to by the new file descriptor.  Using this flag saves extra calls to `fcntl` to achieve
    ///   the same result.
    /// * `SOCK.CLOEXEC`  - Set the close-on-exec (`FD_CLOEXEC`) flag on the new file descriptor.   See  the
    ///   description  of the `CLOEXEC` flag in `open` for reasons why this may be useful.
    ///  Seet posix.accpet()
    flags: u32 = posix.SOCK.CLOEXEC,

    pub const Connection = struct {
        stream: std.net.Stream,
        address: std.net.Address,
    };

    pub fn deinit(s: *Server) void {
        s.stream.close();
        s.* = undefined;
    }

    pub const AcceptError = posix.AcceptError;

    pub fn accept(s: *Server) AcceptError!Connection {
        var accepted_addr: std.net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(std.net.Address);
        const fd = try posix.accept(s.stream.handle, &accepted_addr.any, &addr_len, s.flags);
        return .{
            .stream = .{ .handle = fd },
            // client address
            .address = accepted_addr,
        };
    }
};
