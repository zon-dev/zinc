# zinc

----

Zinc is a framework written in pure Zig with a focus on high performance, usability, security, and extensibility.

**:construction: It's still under development. Built on std.net. Not the fastest zig framework in the universe, but fast enough.**

A basic example:
```zig
const zinc = @import("zinc");

pub fn main() !void {
    var z = try zinc.init(.{ .port = 8080 });

    var router = z.getRouter();
    try router.get("/", helloWorld);

    try z.run();
}

fn helloWorld(ctx: *zinc.Context) anyerror!void {
    try ctx.text("Hello world!", .{});
}
```

### Some features are:
- **Fast**
- **Custom allocator**
- **Multithreading**
- **Middleware**
- **Routes grouping**
- **Rendering built-in**
- **Extensible**
- **Suite of unit tests**
- **Usability**


### Documentation
See more at https://zinc.zon.dev/

#### Quick Start
Learn and practice with the Zinc [Quick Start](https://zinc.zon.dev/src/quickstart.html), which includes API examples and builds tag.

#### Examples
A number of examples demonstrating various use cases of Zinc in the [zinc-examples](https://github.com/zon-dev/zinc-examples) repository.