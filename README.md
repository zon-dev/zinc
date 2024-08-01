# zinc

----

Zinc is a high-performance web framework written in Zig(Ziglang).


### Usage.
```zig
const z = @import("zinc");

pub fn main() !void {
    var engine = try z.Engine.new(.{ .port = 8080 });

    var router = &engine.router;
    try router.get("/", hello_world);

    _ = try engine.run();
}

fn hello_world(ctx: *z.Context, _: *z.Request, _: *z.Response) anyerror!void {
    try ctx.JSON(.{}, .{ .message = "Hello, World!" });
}
```