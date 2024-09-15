const std = @import("std");
const testing = std.testing;
const http = std.http;

const zinc = @import("../zinc.zig");
const Request = zinc.Request;
const Response = zinc.Response;
const Context = zinc.Context;

const Route = zinc.Route;
const Router = zinc.Router;
const RouteError = Route.RouteError;

fn createContext(method: std.http.Method, target: []const u8) anyerror!*Context {
    var req = zinc.Request.init(.{ .method = method, .target = target });
    var res = zinc.Response.init(.{});
    const ctx = try zinc.Context.init(.{ .request = &req, .response = &res });
    return ctx;
}

fn handleRequest(request: *http.Server.Request) void {
    _ = request;
}

test "Zinc with custom Allocator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = true,
        .thread_safe = true,
        .safety = true,
    }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var z = try zinc.init(.{
        .allocator = allocator,
        .num_threads = 10,
    });
    defer z.deinit();

    z.shutdown(1);

    std.debug.print("\n-------------Done: Zinc with custom Allocator-------------n", .{});
}

// test "Zinc Server" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{
//         .verbose_log = true,
//         .thread_safe = true,
//         .safety = true,
//     }){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();

//     var z = try zinc.init(.{ .num_threads = 1, .allocator = allocator });
//     defer z.deinit();

//     var router = z.getRouter();
//     try router.get("/test", testHanle);

//     try std.testing.expectEqual(1, router.getRoutes().items.len);
//     try std.testing.expectEqual(1, router.getRoutes().items[0].handlers.items.len);

//     // Create an HTTP client.
//     var client = std.http.Client{ .allocator = z.allocator };
//     defer client.deinit();
//     const url = try std.fmt.allocPrint(z.allocator, "http://127.0.0.1:{any}/test", .{z.getPort()});
//     var req = try fetch(&client, .{ .method = .GET, .location = .{ .url = url } });
//     defer req.deinit();

//     const body_buffer = req.reader().readAllAlloc(z.allocator, req.response.content_length orelse 8 * 1024) catch unreachable;

//     try std.testing.expectEqualStrings("Hello, World!", body_buffer);

//     // test use middleware
//     try router.use(&.{zinc.Middleware.cors()});
//     try std.testing.expectEqual(1, router.getRoutes().items.len);
//     try std.testing.expectEqual(2, router.getRoutes().items[0].handlers.items.len);

//     // Create an HTTP client.
//     var req2 = try fetch(&client, .{ .method = .GET, .location = .{ .url = url } });
//     defer req2.deinit();

//     // var header_buffer: []u8 = undefined;
//     // header_buffer = try z.allocator.alloc(u8, 1024);
//     // header_buffer = req.response.parser.get();

//     // TODO
//     // Access-Control-Allow-Origin
// }

// fn testHanle(ctx: *Context) anyerror!void {
//     try ctx.text("Hello, World!", .{});
// }

// /// see  std.http.Client.fetch
// fn fetch(client: *std.http.Client, options: std.http.Client.FetchOptions) !std.http.Client.Request {
//     const uri = switch (options.location) {
//         .url => |u| try std.Uri.parse(u),
//         .uri => |u| u,
//     };
//     // var server_header_buffer = options.server_header_buffer orelse (16 * 1024);
//     var server_header_buffer: [1024]u8 = undefined;

//     const method: std.http.Method = options.method orelse
//         if (options.payload != null) .POST else .GET;

//     var req = try std.http.Client.open(client, method, uri, .{
//         .server_header_buffer = options.server_header_buffer orelse &server_header_buffer,
//         .redirect_behavior = options.redirect_behavior orelse
//             if (options.payload == null) @enumFromInt(3) else .unhandled,
//         .headers = options.headers,
//         .extra_headers = options.extra_headers,
//         .privileged_headers = options.privileged_headers,
//         // .keep_alive = options.keep_alive,
//         .keep_alive = false,
//     });

//     if (options.payload) |payload| req.transfer_encoding = .{ .content_length = payload.len };

//     try req.send();

//     if (options.payload) |payload| try req.writeAll(payload);

//     try req.finish();
//     try req.wait();
//     return req;
// }
