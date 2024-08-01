# zinc

----

Zinc is a high-performance web framework written in Zig(Ziglang).


### Usage.
```zig
const z = @import("zinc");

pub fn main() !void {
    var zinc = try z.Engine.new(.{.port = 8080});

    var router = &zinc.router;
    try router.get("/", hello_world);

    try zinc.run();
}

fn hello_world(_: *z.Context, _: *z.Request, res: *z.Response) anyerror!void {
    try res.send("Hello world!");
}
```