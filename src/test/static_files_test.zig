//! Tests for static file and directory registration on the router.
//!
//! `staticFile` and `staticDir` record a URL-to-path mapping and register GET
//! and HEAD routes that consult it. `static` dispatches between the two based
//! on whether the target path has a basename.
//!
//! Both reject URLs containing `*` or `:` with `error.Unreachable`, since those
//! would collide with the trie's wildcard and parameter segments.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Router = zinc.Router;

const harness = @import("harness.zig");

fn newRouter() !*Router {
    return Router.init(.{ .allocator = testing.allocator });
}

fn routeCount(router: *Router) usize {
    const routes = router.getRoutes();
    defer routes.deinit();
    return routes.items.len;
}

// ---------------------------------------------------------------------------
// staticFile
// ---------------------------------------------------------------------------

test "staticFile: records the URL-to-path mapping" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticFile("/index.html", "test_files/index.html");
    try router.staticFile("/logo.png", "test_files/logo.png");

    try testing.expect(router.static_files != null);
    try testing.expect(router.static_files.?.contains("/index.html"));
    try testing.expect(router.static_files.?.contains("/logo.png"));
    try testing.expectEqualStrings("test_files/index.html", router.static_files.?.get("/index.html").?);
    try testing.expectEqualStrings("test_files/logo.png", router.static_files.?.get("/logo.png").?);
}

test "staticFile: registers GET and HEAD routes" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticFile("/index.html", "test_files/index.html");

    try testing.expectEqual(std.http.Method.GET, (try router.getRoute(.GET, "/index.html")).method);
    try testing.expectEqual(std.http.Method.HEAD, (try router.getRoute(.HEAD, "/index.html")).method);
    try testing.expectError(
        zinc.Route.RouteError.MethodNotAllowed,
        router.getRoute(.POST, "/index.html"),
    );
}

test "staticFile: stores an owned copy of the path" {
    var router = try newRouter();
    defer router.deinit();

    var path = "test_files/index.html".*;
    try router.staticFile("/index.html", &path);

    path[0] = 'X';

    try testing.expectEqualStrings("test_files/index.html", router.static_files.?.get("/index.html").?);
}

test "staticFile: re-registering the same URL replaces the path" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticFile("/index.html", "test_files/old.html");
    try router.staticFile("/index.html", "test_files/new.html");

    // The old path must be freed, which the testing allocator verifies.
    try testing.expectEqualStrings("test_files/new.html", router.static_files.?.get("/index.html").?);
}

test "staticFile: rejects a URL containing a wildcard or parameter" {
    var router = try newRouter();
    defer router.deinit();

    try testing.expectError(error.Unreachable, router.staticFile("/file*", "test_files/file.txt"));
    try testing.expectError(error.Unreachable, router.staticFile("/file:name", "test_files/file.txt"));

    try router.staticFile("/valid-file", "test_files/valid-file.txt");
    try testing.expect(router.static_files.?.contains("/valid-file"));
}

test "staticFile: several files can be registered" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticFile("/file1", "test_files/file1.txt");
    try router.staticFile("/file2", "test_files/file2.txt");
    try router.staticFile("/file3", "test_files/file3.txt");

    try testing.expect(router.static_files.?.contains("/file1"));
    try testing.expect(router.static_files.?.contains("/file2"));
    try testing.expect(router.static_files.?.contains("/file3"));
    try testing.expectEqual(@as(u32, 3), router.static_files.?.count());
}

// ---------------------------------------------------------------------------
// staticDir
// ---------------------------------------------------------------------------

test "staticDir: records the URL-to-directory mapping" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticDir("/assets", "test_files/assets");
    try router.staticDir("/images", "test_files/images");

    try testing.expect(router.static_dirs != null);
    try testing.expect(router.static_dirs.?.contains("/assets"));
    try testing.expect(router.static_dirs.?.contains("/images"));
    try testing.expectEqualStrings("test_files/assets", router.static_dirs.?.get("/assets").?);
    try testing.expectEqualStrings("test_files/images", router.static_dirs.?.get("/images").?);
}

test "staticDir: registers GET and HEAD routes" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticDir("/assets", "test_files/assets");

    try testing.expectEqual(std.http.Method.GET, (try router.getRoute(.GET, "/assets")).method);
    try testing.expectEqual(std.http.Method.HEAD, (try router.getRoute(.HEAD, "/assets")).method);
}

test "staticDir: stores an owned copy of the directory path" {
    var router = try newRouter();
    defer router.deinit();

    var path = "test_files/assets".*;
    try router.staticDir("/assets", &path);

    path[0] = 'X';

    try testing.expectEqualStrings("test_files/assets", router.static_dirs.?.get("/assets").?);
}

test "staticDir: re-registering the same URL replaces the path" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticDir("/assets", "test_files/old");
    try router.staticDir("/assets", "test_files/new");

    try testing.expectEqualStrings("test_files/new", router.static_dirs.?.get("/assets").?);
}

test "staticDir: rejects a URL containing a wildcard or parameter" {
    var router = try newRouter();
    defer router.deinit();

    try testing.expectError(error.Unreachable, router.staticDir("/dir*", "test_files/dir"));
    try testing.expectError(error.Unreachable, router.staticDir("/dir:name", "test_files/dir"));

    try router.staticDir("/valid-dir", "test_files/valid-dir");
    try testing.expect(router.static_dirs.?.contains("/valid-dir"));
}

test "staticDir: several directories can be registered" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticDir("/dir1", "test_files/dir1");
    try router.staticDir("/dir2", "test_files/dir2");
    try router.staticDir("/dir3", "test_files/dir3");

    try testing.expect(router.static_dirs.?.contains("/dir1"));
    try testing.expect(router.static_dirs.?.contains("/dir2"));
    try testing.expect(router.static_dirs.?.contains("/dir3"));
    try testing.expectEqual(@as(u32, 3), router.static_dirs.?.count());
}

// ---------------------------------------------------------------------------
// Files and directories together
// ---------------------------------------------------------------------------

test "static registration: files and directories coexist" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticFile("/", "test_files/index.html");
    try router.staticDir("/assets", "test_files/assets");
    try router.staticFile("/favicon.ico", "test_files/favicon.ico");
    try router.staticDir("/images", "test_files/images");

    try testing.expect(router.static_files != null);
    try testing.expect(router.static_dirs != null);

    try testing.expect(router.static_files.?.contains("/"));
    try testing.expect(router.static_files.?.contains("/favicon.ico"));
    try testing.expectEqualStrings("test_files/index.html", router.static_files.?.get("/").?);
    try testing.expectEqualStrings("test_files/favicon.ico", router.static_files.?.get("/favicon.ico").?);

    try testing.expect(router.static_dirs.?.contains("/assets"));
    try testing.expect(router.static_dirs.?.contains("/images"));
    try testing.expectEqualStrings("test_files/assets", router.static_dirs.?.get("/assets").?);
    try testing.expectEqualStrings("test_files/images", router.static_dirs.?.get("/images").?);
}

test "static registration: files and directories use separate maps" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticFile("/same", "test_files/file.txt");
    try router.staticDir("/same-dir", "test_files/dir");

    try testing.expect(router.static_files.?.contains("/same"));
    try testing.expect(!router.static_files.?.contains("/same-dir"));
    try testing.expect(router.static_dirs.?.contains("/same-dir"));
    try testing.expect(!router.static_dirs.?.contains("/same"));
}

// ---------------------------------------------------------------------------
// static() dispatch
// ---------------------------------------------------------------------------

test "static: a path with a basename registers a file" {
    var router = try newRouter();
    defer router.deinit();

    try router.static("/index.html", "test_files/index.html");

    try testing.expect(router.static_files.?.contains("/index.html"));
    try testing.expect(!router.static_dirs.?.contains("/index.html"));
}

test "static: a trailing slash still registers a file, not a directory" {
    var router = try newRouter();
    defer router.deinit();

    // KNOWN ISSUE: `static` picks the directory branch only when
    // `std.fs.path.basename(path).len == 0`, but `basename` strips trailing
    // slashes, so "test_files/assets/" yields "assets" and takes the file
    // branch. Combined with the earlier `""` and `"/"` rejections, the
    // `staticDir` branch is effectively unreachable through `static`.
    // Callers that want a directory must call `staticDir` directly.
    try router.static("/assets", "test_files/assets/");

    try testing.expect(router.static_files.?.contains("/assets"));
    try testing.expect(!router.static_dirs.?.contains("/assets"));
}

test "static: rejects an empty relative path" {
    var router = try newRouter();
    defer router.deinit();

    try testing.expectError(error.Empty, router.static("", "test_files/index.html"));
}

test "static: refuses to serve the filesystem root" {
    var router = try newRouter();
    defer router.deinit();

    try testing.expectError(error.AccessDenied, router.static("/root", "/"));
    try testing.expectError(error.AccessDenied, router.static("/empty", ""));
}

test "static: rejects a target path containing a wildcard or parameter" {
    var router = try newRouter();
    defer router.deinit();

    try testing.expectError(error.Unreachable, router.static("/ok", "test_files/*"));
    try testing.expectError(error.Unreachable, router.static("/ok", "test_files/:name"));
}

// ---------------------------------------------------------------------------
// Serving
// ---------------------------------------------------------------------------

test "static file serving: fails outside a connection because the router is global" {
    var router = try newRouter();
    defer router.deinit();

    try router.staticFile("/style.css", "src/test/assets/style.css");

    var tc = try harness.newContext(testing.allocator, .{ .target = "/style.css" });
    defer tc.deinit();

    // KNOWN LIMITATION: the static handlers resolve their path through a
    // file-scope `current_router` global that only `handleConn` assigns, so a
    // static route cannot be exercised through `handleContext` or by calling
    // the handler directly. This test pins the current behaviour; if the
    // handlers are changed to resolve the path from the context or route
    // instead, it should become an assertion that the file is served.
    const route = try router.getRoute(.GET, "/style.css");
    try testing.expectError(error.RouterNotSet, harness.runChain(tc.ctx, route));
}

test "static file serving: ctx.file serves the same asset directly" {
    // The end-to-end equivalent of the test above, bypassing the global.
    var tc = try harness.newContext(testing.allocator, .{ .target = "/style.css" });
    defer tc.deinit();

    try tc.ctx.file("src/test/assets/style.css", .{});

    try harness.expectBody(tc.ctx, "/* style.css */");
}

test "static registration: routes are counted alongside normal routes" {
    var router = try newRouter();
    defer router.deinit();

    try router.get("/api", harness.textHandler("api"));
    try router.staticFile("/style.css", "src/test/assets/style.css");

    // One GET for /api, plus GET and HEAD for the static file.
    try testing.expectEqual(@as(usize, 3), routeCount(router));
}
