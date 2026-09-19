//! Static file and directory registration on the router.
//!
//! `staticFile` / `staticDir` record a URL-to-path mapping and register GET
//! and HEAD routes. `static` dispatches between them based on basename.
//! URLs containing `*` or `:` are rejected (`error.Unreachable`).

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const RouteError = zinc.Route.RouteError;
const harness = @import("harness.zig");

test "staticFile: records mapping, owns the path, registers GET and HEAD" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    var path = "test_files/index.html".*;
    try app.router.staticFile("/index.html", &path);
    path[0] = 'X';
    try app.router.staticFile("/logo.png", "test_files/logo.png");
    try app.router.staticFile("/index.html", "test_files/new.html");

    try testing.expectEqualStrings("test_files/new.html", app.router.static_files.?.get("/index.html").?);
    try testing.expectEqualStrings("test_files/logo.png", app.router.static_files.?.get("/logo.png").?);
    try testing.expectEqual(std.http.Method.GET, (try app.router.getRoute(.GET, "/index.html")).method);
    try testing.expectEqual(std.http.Method.HEAD, (try app.router.getRoute(.HEAD, "/index.html")).method);
    try testing.expectError(RouteError.MethodNotAllowed, app.router.getRoute(.POST, "/index.html"));

    try testing.expectError(error.Unreachable, app.router.staticFile("/file*", "test_files/file.txt"));
    try testing.expectError(error.Unreachable, app.router.staticFile("/file:name", "test_files/file.txt"));
    try app.router.staticFile("/valid-file", "test_files/valid-file.txt");
    try testing.expect(app.router.static_files.?.contains("/valid-file"));

    try app.router.staticFile("/file1", "test_files/file1.txt");
    try app.router.staticFile("/file2", "test_files/file2.txt");
    try app.router.staticFile("/file3", "test_files/file3.txt");
    try testing.expectEqual(@as(u32, 6), app.router.static_files.?.count());
}

test "staticDir: records mapping, owns the path, registers GET and HEAD" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    var path = "test_files/assets".*;
    try app.router.staticDir("/assets", &path);
    path[0] = 'X';
    try app.router.staticDir("/images", "test_files/images");
    try app.router.staticDir("/assets", "test_files/new");

    try testing.expectEqualStrings("test_files/new", app.router.static_dirs.?.get("/assets").?);
    try testing.expectEqualStrings("test_files/images", app.router.static_dirs.?.get("/images").?);
    try testing.expectEqual(std.http.Method.GET, (try app.router.getRoute(.GET, "/assets")).method);
    try testing.expectEqual(std.http.Method.HEAD, (try app.router.getRoute(.HEAD, "/assets")).method);

    try testing.expectError(error.Unreachable, app.router.staticDir("/dir*", "test_files/dir"));
    try testing.expectError(error.Unreachable, app.router.staticDir("/dir:name", "test_files/dir"));
    try app.router.staticDir("/valid-dir", "test_files/valid-dir");

    try app.router.staticDir("/dir1", "test_files/dir1");
    try app.router.staticDir("/dir2", "test_files/dir2");
    try app.router.staticDir("/dir3", "test_files/dir3");
    try testing.expectEqual(@as(u32, 6), app.router.static_dirs.?.count());
}

test "static registration: files and directories coexist in separate maps" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    try app.router.staticFile("/", "test_files/index.html");
    try app.router.staticDir("/assets", "test_files/assets");
    try app.router.staticFile("/favicon.ico", "test_files/favicon.ico");
    try app.router.staticDir("/images", "test_files/images");
    try app.router.staticFile("/same", "test_files/file.txt");
    try app.router.staticDir("/same-dir", "test_files/dir");

    try testing.expect(app.router.static_files.?.contains("/"));
    try testing.expect(app.router.static_files.?.contains("/favicon.ico"));
    try testing.expect(!app.router.static_files.?.contains("/same-dir"));
    try testing.expect(app.router.static_dirs.?.contains("/assets"));
    try testing.expect(app.router.static_dirs.?.contains("/same-dir"));
    try testing.expect(!app.router.static_dirs.?.contains("/same"));
}

test "static: dispatch, empty path, filesystem root, wildcards" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();

    try app.router.static("/index.html", "test_files/index.html");
    try testing.expect(app.router.static_files.?.contains("/index.html"));
    try testing.expect(!app.router.static_dirs.?.contains("/index.html"));

    // KNOWN ISSUE: `basename` strips trailing slashes, so a trailing `/` still
    // takes the file branch. Callers that want a directory must call `staticDir`.
    try app.router.static("/assets", "test_files/assets/");
    try testing.expect(app.router.static_files.?.contains("/assets"));

    try testing.expectError(error.Empty, app.router.static("", "test_files/index.html"));
    try testing.expectError(error.AccessDenied, app.router.static("/root", "/"));
    try testing.expectError(error.AccessDenied, app.router.static("/empty", ""));
    try testing.expectError(error.Unreachable, app.router.static("/ok", "test_files/*"));
    try testing.expectError(error.Unreachable, app.router.static("/ok", "test_files/:name"));
}

test "static file serving: router global is unset outside handleConn" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try app.router.staticFile("/style.css", harness.assets.style_css);

    try testing.expectError(error.RouterNotSet, app.get("/style.css"));

    var tc = try harness.newContext(testing.allocator, .{ .target = "/style.css" });
    defer tc.deinit();
    try tc.ctx.file(harness.assets.style_css, .{});
    try harness.expectBody(tc.ctx, harness.assets.style_css_body);

    try app.router.get("/api", harness.text("api"));
    try testing.expectEqual(@as(usize, 3), harness.routeCount(app.router));
}
