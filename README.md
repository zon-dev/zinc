# zinc

Zinc is an HTTP framework written in Zig. I/O is asynchronous via [aio](https://github.com/zon-dev/aio) (`io_uring` on Linux, `kqueue` on macOS). Handlers run **inline on the accept/read worker**, so a keep-alive request does not hop through another thread pool or wait for an extra event-loop tick to send.

**:construction: Still in active development. Do not use it in production until a stable release.**

Requires **Zig 0.17**.

## Throughput (keep-alive)

Best `zig build perf` result so far, loopback, macOS, ReleaseFast, 1000 ms windows:

| Keep-alive clients | Plaintext |
| ---: | ---: |
| 1 | 62,883 req/s |
| 2 | 102,502 req/s |
| 4 | 130,704 req/s |
| 8 | 130,763 req/s |
| 16 | 148,763 req/s |
| **32** | **163,806 req/s** |

Same run, other keep-alive checks: plaintext 1 client 42,614 req/s; JSON 1 client 31,597 req/s; plaintext 8 clients 130,875 req/s. Zero stalled responses, zero errors.

The pre-optimization baseline on this same keep-alive plaintext workload was **34,892 req/s**. Sequential one-connection-per-request HTTP is much slower (~10–17k req/s) because it is dominated by `connect`/`accept`, not by `ctx.text`.

These numbers are loopback. They are zinc against its own baseline, not a cross-framework bake-off.

Reproduce:

```bash
zig build perf
```

## Recommended engine config

This is the configuration that produced the table above (`num_threads = 4`, 32 keep-alive connections, tiny `Content-Length` bodies):

```zig
var z = try zinc.init(.{
    .addr = "0.0.0.0",
    .port = 8080,
    .num_threads = 4,
    .read_buffer_len = 8192,
    .header_buffer_len = 1024,
    .body_buffer_len = 4096,
    .stack_size = 1024 * 1024,
    .max_conn = 10_000,
});
```

What actually matters for that result:

- **Keep the connection open.** Speak HTTP/1.1 keep-alive. Do not send `Connection: close`. The server already enables `TCP_NODELAY` and non-blocking sockets on accept.
- **Use `Content-Length` responses.** `ctx.text` / `ctx.json` do this. Handlers run on the AIO worker and send immediately; the serialized bytes live in the per-connection arena until the write completes.
- **Size worker threads to the machine, not to client count.** The sweep peaked at 32 *connections* with **4** engine threads. Extra threads did not produce that number.
- **Keep read/header/body buffers tight** for plaintext/JSON. Raise `body_buffer_len` when you accept larger uploads.
- **Reuse the connection in the client.** A load generator that opens a new TCP connection per request is measuring accept latency, not handler throughput.

`SO_REUSEPORT` is set on each worker listener so the kernel can spread accepts across the 4 threads.

## Quick start

```zig
const zinc = @import("zinc");

pub fn main() !void {
    var z = try zinc.init(.{
        .addr = "0.0.0.0",
        .port = 8080,
        .num_threads = 4,
        .read_buffer_len = 8192,
        .header_buffer_len = 1024,
        .body_buffer_len = 4096,
        .stack_size = 1024 * 1024,
        .max_conn = 10_000,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/plaintext", plaintext);
    try router.get("/json", json);

    try z.run();
}

fn plaintext(ctx: *zinc.Context) anyerror!void {
    try ctx.text("Hello, World!", .{});
}

fn json(ctx: *zinc.Context) anyerror!void {
    try ctx.json(.{ .message = "Hello, World!" }, .{});
}
```

HTTP/1.1 keep-alive is on unless the client sends `Connection: close`.

## Installation

```zig
zig fetch --save https://github.com/zon-dev/zinc/archive/refs/heads/main.zip
```

## Routing and middleware

```zig
var router = z.getRouter();
var api = try router.group("/api");
try api.get("/users", getUsers);
try api.post("/users", createUser);

var v1 = try api.group("/v1");
try v1.get("/status", getStatus);

try router.use(&.{authMiddleware, corsMiddleware});
try router.get("/protected", protectedHandler);

try router.staticFile("/favicon.ico", "public/favicon.ico");
try router.staticDir("/assets", "public/assets");
```

## Platform support

| OS | Backend |
| --- | --- |
| Linux | `io_uring` (kernel 5.5+) |
| macOS | `kqueue` |
| Windows | IOCP planned |

## Testing

```bash
zig build test          # Debug, full suite
zig build perf          # ReleaseFast, names prefixed `perf:`
```

`zig build perf` is the throughput gate. Keep-alive floors are 10k req/s in ReleaseFast; the table above is what the current engine actually measured.

## Documentation

- API reference: https://zinc.zon.dev/
- Quick start: https://zinc.zon.dev/src/quickstart.html

## License

MIT. See `LICENSE`.
