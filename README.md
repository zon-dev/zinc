# zinc

----

Zinc is a high-performance web framework written in Zig(Ziglang).


### Usage.

```zig
const z = @import("zinc");

pub fn main() !void {
    var zinc = try z.Engine.init(.{ .port = 8080 });

    var router = zinc.getRouter();
    try router.get("/", helloWorld);
    try router.add(&.{ .GET, .POST }, "/ping", pong);

    var catchers = zinc.getCatchers();
    try catchers.put(.not_found, notFound);
    try catchers.put(.forbidden, forbidden)

    try zinc.run();
}

fn pong(ctx: *z.Context, _: *z.Request, _: *z.Response) anyerror!void {
    try ctx.Text(.{}, "pong!");
}

fn helloWorld(ctx: *z.Context, _: *z.Request, _: *z.Response) anyerror!void {
    try ctx.JSON(.{}, .{ .message = "Hello, World!" });
}

// Default 404 (not found) page
fn notFound(ctx: *z.Context, _: *z.Request, _: *z.Response) anyerror!void {
    try ctx.HTML(.{
        .status = .not_found,
    }, "<h1>404 Not Found</h1>");
}

// Default 403 (access denied) page
fn forbidden(ctx: *z.Context, _: *z.Request, _: *z.Response) anyerror!void {
    try ctx.HTML(.{
        .status = .forbidden,
    }, "<h1>403 Access Denied</h1>");
}

```