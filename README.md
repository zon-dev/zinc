# zinc

----

Zinc is a high-performance web framework written in Zig(Ziglang).


### Usage.

```zig
const zinc = @import("zinc");

pub fn main() !void {
    var z = try zinc.init(.{ .port = 8080 });

    var router = z.getRouter();
    try router.get("/", helloWorld);
    try router.add(&.{ .GET, .POST }, "/ping", pong);

    var catchers = z.getCatchers();
    try catchers.setNotFound(notFound);

    try z.run();
}

fn pong(ctx: *zinc.Context, _: *zinc.Request, _: *zinc.Response) anyerror!void {
    try ctx.Text(.{}, "pong!");
}

fn helloWorld(ctx: *zinc.Context, _: *zinc.Request, _: *zinc.Response) anyerror!void {
    try ctx.JSON(.{}, .{ .message = "Hello, World!" });
}

// Default 404 (not found) page
fn notFound(ctx: *zinc.Context, _: *zinc.Request, _: *zinc.Response) anyerror!void {
    try ctx.HTML(.{
        .status = .not_found,
    }, "<h1>404 Not Found</h1>");
}

```