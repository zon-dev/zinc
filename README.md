# zinc

----

Zinc is a high-performance web framework written in Zig(Ziglang).


### Usage.
```zig
const z = @import("zinc");

pub fn main() !void {
    var zinc = try z.Engine.init(.{ .port = 8080 });

    var router = zinc.getRouter();
    try router.get("/", hello_world);
    try router.get("/ping", pong);

    try zinc.run();
}


fn pong(ctx: *z.Context, _: *z.Request, _: *z.Response) anyerror!void {
    try ctx.Text(.{}, "pong!");
}

fn hello_world(ctx: *z.Context, _: *z.Request, _: *z.Response) anyerror!void {
    try ctx.JSON(.{}, .{ .message = "Hello, World!" });
}
```