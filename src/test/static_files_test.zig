const std = @import("std");
const testing = std.testing;
const zinc = @import("../zinc.zig");

test "static file handling" {
    const allocator = testing.allocator;

    // 创建 router
    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    // 注册静态文件
    try router.staticFile("/index.html", "test_files/index.html");
    try router.staticFile("/logo.png", "test_files/logo.png");

    // 验证静态文件映射是否正确
    try testing.expect(router.static_files != null);
    try testing.expect(router.static_files.?.contains("/index.html"));
    try testing.expect(router.static_files.?.contains("/logo.png"));

    // 验证文件路径
    const index_path = router.static_files.?.get("/index.html").?;
    const logo_path = router.static_files.?.get("/logo.png").?;
    try testing.expectEqualStrings("test_files/index.html", index_path);
    try testing.expectEqualStrings("test_files/logo.png", logo_path);
}

test "static directory handling" {
    const allocator = testing.allocator;

    // 创建 router
    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    // 注册静态目录
    try router.staticDir("/assets", "test_files/assets");
    try router.staticDir("/images", "test_files/images");

    // 验证静态目录映射是否正确
    try testing.expect(router.static_dirs != null);
    try testing.expect(router.static_dirs.?.contains("/assets"));
    try testing.expect(router.static_dirs.?.contains("/images"));

    // 验证目录路径
    const assets_path = router.static_dirs.?.get("/assets").?;
    const images_path = router.static_dirs.?.get("/images").?;
    try testing.expectEqualStrings("test_files/assets", assets_path);
    try testing.expectEqualStrings("test_files/images", images_path);
}

test "static file and directory mixed" {
    const allocator = testing.allocator;

    // 创建 router
    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    // 混合注册静态文件和目录
    try router.staticFile("/", "test_files/index.html");
    try router.staticDir("/assets", "test_files/assets");
    try router.staticFile("/favicon.ico", "test_files/favicon.ico");
    try router.staticDir("/images", "test_files/images");

    // 验证所有映射都存在
    try testing.expect(router.static_files != null);
    try testing.expect(router.static_dirs != null);

    // 验证静态文件
    try testing.expect(router.static_files.?.contains("/"));
    try testing.expect(router.static_files.?.contains("/favicon.ico"));
    try testing.expectEqualStrings("test_files/index.html", router.static_files.?.get("/").?);
    try testing.expectEqualStrings("test_files/favicon.ico", router.static_files.?.get("/favicon.ico").?);

    // 验证静态目录
    try testing.expect(router.static_dirs.?.contains("/assets"));
    try testing.expect(router.static_dirs.?.contains("/images"));
    try testing.expectEqualStrings("test_files/assets", router.static_dirs.?.get("/assets").?);
    try testing.expectEqualStrings("test_files/images", router.static_dirs.?.get("/images").?);
}

test "static file path validation" {
    const allocator = testing.allocator;

    // 创建 router
    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    // 测试无效路径（包含通配符）
    try testing.expectError(error.Unreachable, router.staticFile("/file*", "test_files/file.txt"));
    try testing.expectError(error.Unreachable, router.staticFile("/file:name", "test_files/file.txt"));

    // 测试有效路径
    try router.staticFile("/valid-file", "test_files/valid-file.txt");
    try testing.expect(router.static_files.?.contains("/valid-file"));
}

test "static directory path validation" {
    const allocator = testing.allocator;

    // 创建 router
    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    // 测试无效路径（包含通配符）
    try testing.expectError(error.Unreachable, router.staticDir("/dir*", "test_files/dir"));
    try testing.expectError(error.Unreachable, router.staticDir("/dir:name", "test_files/dir"));

    // 测试有效路径
    try router.staticDir("/valid-dir", "test_files/valid-dir");
    try testing.expect(router.static_dirs.?.contains("/valid-dir"));
}

test "static file memory management" {
    const allocator = testing.allocator;

    // 创建 router
    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    // 注册多个静态文件
    try router.staticFile("/file1", "test_files/file1.txt");
    try router.staticFile("/file2", "test_files/file2.txt");
    try router.staticFile("/file3", "test_files/file3.txt");

    // 验证映射存在
    try testing.expect(router.static_files.?.contains("/file1"));
    try testing.expect(router.static_files.?.contains("/file2"));
    try testing.expect(router.static_files.?.contains("/file3"));
}

test "static directory memory management" {
    const allocator = testing.allocator;

    // 创建 router
    var router = try zinc.Router.init(.{
        .allocator = allocator,
    });
    defer router.deinit();

    // 注册多个静态目录
    try router.staticDir("/dir1", "test_files/dir1");
    try router.staticDir("/dir2", "test_files/dir2");
    try router.staticDir("/dir3", "test_files/dir3");

    // 验证映射存在
    try testing.expect(router.static_dirs.?.contains("/dir1"));
    try testing.expect(router.static_dirs.?.contains("/dir2"));
    try testing.expect(router.static_dirs.?.contains("/dir3"));
}
