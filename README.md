# zinc

----

Zinc is a high-performance web framework written in pure Zig with a focus on usability, security, and extensibility. It features **asynchronous I/O powered by the aio library** for maximum performance across all supported platforms.

**:rocket: Now with async I/O support via aio library for fast performance!**

**:construction: It's still in active development. Not the fastest zig framework in the universe, but fast enough.**

**:warning: Do not use it in production environments until the stable release.**

## 🚀 Key Features

- **⚡ Asynchronous I/O**: Powered by the aio library for maximum performance
- **🔄 Cross-platform**: Linux (io_uring), macOS (kqueue), Windows (IOCP planned)
- **🧵 Multithreading**: Efficient thread pool management
- **🔧 Middleware Support**: Flexible middleware system
- **📁 Route Groups**: Organized routing with nested groups
- **🎨 Built-in Rendering**: Template and static file support
- **🔒 Security Focused**: Built with security best practices
- **🧪 Comprehensive Testing**: Full test suite coverage
- **📚 Extensible**: Easy to extend and customize

## 🏗️ Architecture

Zinc uses a modern async/await architecture with the aio library:

- **Event Loop**: Non-blocking I/O operations
- **Callback-based**: Efficient async callbacks for I/O completion
- **Connection Pooling**: Optimized connection management
- **Memory Safety**: Zero-copy operations where possible

## 📦 Installation

Add zinc to your `build.zig.zon`:

```zig
zig fetch --save https://github.com/zon-dev/zinc/archive/refs/heads/main.zip
```

## 🚀 Quick Start

A basic example with async I/O:

```zig
const zinc = @import("zinc");

pub fn main() !void {
    var z = try zinc.init(.{ 
        .port = 8080,
        .num_threads = 4,  // Configure thread pool
        .force_nonblocking = true,  // Enable async I/O
    });
    defer z.deinit();
    
    var router = z.getRouter();
    try router.get("/", helloWorld);

    try z.run();
}

fn helloWorld(ctx: *zinc.Context) anyerror!void {
    try ctx.text("Hello world!", .{});
}
```

## 🛠️ Advanced Usage

### Route Groups

```zig
var router = z.getRouter();
var api = try router.group("/api");
try api.get("/users", getUsers);
try api.post("/users", createUser);

var v1 = try api.group("/v1");
try v1.get("/status", getStatus);
```

### Middleware

```zig
// Global middleware
try router.use(&.{authMiddleware, corsMiddleware});

// Route-specific middleware
try router.get("/protected", protectedHandler);
```

### Async I/O Configuration

```zig
var z = try zinc.init(.{
    .port = 8080,
    .num_threads = 8,           // Worker threads
    .read_buffer_len = 8192,    // Read buffer size
    .force_nonblocking = true,  // Enable async I/O
    .stack_size = 1048576,      // Thread stack size
});
```

## 🖥️ Platform Support

### Linux
- **io_uring**: Maximum performance with Linux kernel 5.5+
- **Zero-copy**: Efficient memory operations
- **Batch operations**: High-throughput I/O

### macOS
- **kqueue**: Native async I/O support
- **Optimized**: macOS-specific optimizations
- **Full feature support**: All async operations

### Windows
- **IOCP**: Planned for future releases
- **Native async**: Windows-native I/O completion ports

## 📊 Performance

Zinc with aio integration provides:

- **High concurrency**: Handle thousands of concurrent connections
- **Low latency**: Sub-millisecond response times
- **Efficient memory usage**: Minimal memory overhead
- **Scalable**: Linear scaling with CPU cores

## 🧪 Testing

Run the comprehensive test suite:

```bash
zig build test
```

All tests pass with zero memory leaks and full async I/O coverage.

## 📚 Documentation

- **API Reference**: https://zinc.zon.dev/
- **Quick Start Guide**: https://zinc.zon.dev/src/quickstart.html
- **Examples Repository**: https://github.com/zon-dev/zinc-examples

## 🔧 Development

### Building

```bash
git clone https://github.com/zon-dev/zinc.git
cd zinc
zig build
```

### Running Tests

```bash
zig build test
```

### Running Examples

```bash
zig build run-example
```

## 🤝 Contributing

We welcome contributions! Please see our contributing guidelines for details.

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments

- **aio library**: For providing excellent cross-platform async I/O
- **Zig community**: For the amazing language and ecosystem
- **Contributors**: Everyone who has helped make zinc better

---

**:star: Star this repository if you find it useful!**