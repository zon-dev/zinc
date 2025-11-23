const std = @import("std");
const posix = std.posix;
const Io = std.Io;

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
};

/// The returned `Server` has an open socket.
pub fn listen(address: Io.net.IpAddress, options: ListenOptions) !Server {
    // Convert IpAddress to sockaddr for posix operations
    // Use a larger buffer to accommodate both IPv4 and IPv6 (sockaddr.in6 is 28 bytes)
    var sockaddr_buffer: [128]u8 = undefined;
    var socklen: posix.socklen_t = undefined;
    var family: posix.sa_family_t = undefined;
    const sockaddr: *posix.sockaddr = @ptrCast(&sockaddr_buffer);

    // Convert IpAddress to sockaddr for posix operations
    // IpAddress is a union with .ip4 and .ip6 fields
    switch (address) {
        .ip4 => |ip4| {
            var sa: posix.sockaddr.in = undefined;
            sa.family = posix.AF.INET;
            sa.port = std.mem.nativeToBig(u16, ip4.port);
            // ip4.bytes stores address as [a, b, c, d] for a.b.c.d
            // sockaddr.in.addr.s_addr needs network byte order (big-endian) u32
            // So we construct: (a << 24) | (b << 16) | (c << 8) | d
            const addr_u32 = (@as(u32, ip4.bytes[0]) << 24) |
                (@as(u32, ip4.bytes[1]) << 16) |
                (@as(u32, ip4.bytes[2]) << 8) |
                (@as(u32, ip4.bytes[3]));
            // On macOS, sockaddr.in.addr is a struct with s_addr field
            // We need to set it properly
            sa.addr = @bitCast(std.mem.nativeToBig(u32, addr_u32));
            // Copy the entire sockaddr.in structure
            @memcpy(@as(*[@sizeOf(posix.sockaddr.in)]u8, @ptrCast(sockaddr)), @as(*const [@sizeOf(posix.sockaddr.in)]u8, @ptrCast(&sa)));
            socklen = @sizeOf(posix.sockaddr.in);
            family = posix.AF.INET;
        },
        .ip6 => |ip6| {
            var sa: posix.sockaddr.in6 = undefined;
            sa.family = posix.AF.INET6;
            sa.port = std.mem.nativeToBig(u16, ip6.port);
            @memcpy(&sa.addr, &ip6.bytes);
            // Copy bytes directly - use sockaddr_storage which is large enough
            @memcpy(@as(*[@sizeOf(posix.sockaddr.in6)]u8, @ptrCast(sockaddr)), @as(*const [@sizeOf(posix.sockaddr.in6)]u8, @ptrCast(&sa)));
            socklen = @sizeOf(posix.sockaddr.in6);
            family = posix.AF.INET6;
        },
    }

    const nonblock: u32 = posix.SOCK.NONBLOCK;
    const posix_flags: u32 = posix.SOCK.CLOEXEC | nonblock;
    var sock_flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    sock_flags |= nonblock;

    const proto: u32 = if (family == posix.AF.UNIX) 0 else posix.IPPROTO.TCP;
    const sockfd = try posix.socket(family, sock_flags, proto);

    var s: Server = .{
        .flags = posix_flags,
        .listen_address = undefined,
        .socket_fd = sockfd,
    };
    errdefer posix.close(sockfd);

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

    // Bind using the sockaddr - ensure we pass const pointer
    try posix.bind(sockfd, @as(*const posix.sockaddr, @ptrCast(&sockaddr_buffer)), socklen);
    // Increase kernel backlog for better connection handling under load
    const backlog = if (options.kernel_backlog < 4096) 4096 else options.kernel_backlog;
    try posix.listen(sockfd, backlog);

    // Get the actual bound address to extract the real port (especially if port was 0)
    var bound_addr: posix.sockaddr = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(sockfd, &bound_addr, &bound_len);

    // Extract the actual port from bound_addr and update the address
    const actual_port: u16 = switch (bound_addr.family) {
        posix.AF.INET => blk: {
            const sa_in = @as(*const posix.sockaddr.in, @alignCast(@ptrCast(&bound_addr)));
            break :blk std.mem.bigToNative(u16, sa_in.port);
        },
        posix.AF.INET6 => blk: {
            const sa_in6 = @as(*const posix.sockaddr.in6, @alignCast(@ptrCast(&bound_addr)));
            break :blk std.mem.bigToNative(u16, sa_in6.port);
        },
        else => address.getPort(), // Fallback to original port
    };

    // Update the address with the actual port
    var updated_address = address;
    switch (updated_address) {
        inline .ip4, .ip6 => |*addr| addr.port = actual_port,
    }
    s.listen_address = updated_address;

    return s;
}

pub const Server = struct {
    listen_address: Io.net.IpAddress,
    socket_fd: posix.socket_t,

    /// The following values can be bitwise ORed in flags to obtain different behavior:
    /// * `SOCK.NONBLOCK` - Set the `NONBLOCK` file status flag on the open file description (see `open`)
    ///   referred  to by the new file descriptor.  Using this flag saves extra calls to `fcntl` to achieve
    ///   the same result.
    /// * `SOCK.CLOEXEC`  - Set the close-on-exec (`FD_CLOEXEC`) flag on the new file descriptor.   See  the
    ///   description  of the `CLOEXEC` flag in `open` for reasons why this may be useful.
    ///  See posix.accept()
    flags: u32 = posix.SOCK.CLOEXEC,

    pub const Connection = struct {
        socket_fd: posix.socket_t,
        address: Io.net.IpAddress,
    };

    pub fn deinit(s: *Server) void {
        posix.close(s.socket_fd);
        s.* = undefined;
    }

    pub const AcceptError = posix.AcceptError;

    pub fn accept(s: *Server) AcceptError!Connection {
        var accepted_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const fd = try posix.accept(s.socket_fd, &accepted_addr, &addr_len, s.flags);

        // Convert sockaddr to IpAddress
        // For now, create a default address since we don't need the client address for our use case
        const address = try Io.net.IpAddress.parse("0.0.0.0", 0);

        return .{
            .socket_fd = fd,
            // client address (not used in our implementation)
            .address = address,
        };
    }
};
