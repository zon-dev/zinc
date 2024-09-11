# zinc

----

Zinc is a framework written in pure Zig with a focus on high performance, usability, security, and extensibility.

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


### Documentation
See more at https://zinc.zon.dev/

#### Quick Start
Learn and practice with the Zinc [Quick Start](https://zinc.zon.dev/src/quickstart.html), which includes API examples and builds tag.

#### Examples
A number of examples demonstrating various use cases of Zinc in the [zinc-examples](https://github.com/zon-dev/zinc-examples) repository.