//! `RouteTree` — the trie the router stores routes in.
//!
//! `insert` splits on `/`; `:name` is a named parameter and `*` a wildcard.
//! `find` is exact; `findWithWildcard` also traverses parameter/wildcard nodes.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const harness = @import("harness.zig");

test "RouteTree: insert builds one node per segment and reuses shared prefixes" {
    var root = try harness.newTree(testing.allocator);
    defer root.destroyTrieTree();

    try testing.expectEqualStrings("/", root.value);
    try testing.expectEqual(@as(u32, 0), root.children.?.count());
    try testing.expectEqual(root, try root.insert("/"));

    const leaf = try root.insert("/test/route");
    try testing.expectEqualStrings("route", leaf.value);
    try testing.expectEqualStrings("/test/route", leaf.full_path);

    _ = try root.insert("/a/b/c");
    try testing.expectEqualStrings("a", root.find("/a").?.value);
    try testing.expectEqualStrings("b", root.find("/a/b").?.value);
    try testing.expectEqualStrings("c", root.find("/a/b/c").?.value);

    const first = try root.insert("/dup/path");
    try testing.expectEqual(first, try root.insert("/dup/path"));

    _ = try root.insert("/shared/one");
    _ = try root.insert("/shared/two");
    try testing.expectEqual(@as(u32, 2), root.find("/shared").?.children.?.count());

    const single = try root.insert("/single");
    try testing.expectEqualStrings("single", single.value);

    try testing.expectEqualStrings("noslash", (try root.insert("noslash")).value);
    try testing.expect(root.find("/a/b/c/d/e/f/g/h") == null);
    _ = try root.insert("/a/b/c/d/e/f/g/h");
    try testing.expect(root.find("/a/b/c/d/e/f/g/h") != null);
}

test "RouteTree: insert records named parameters and wildcards" {
    var root = try harness.newTree(testing.allocator);
    defer root.destroyTrieTree();

    _ = try root.insert("/user/:id");
    const param = root.find("/user").?.children.?.get("id") orelse return error.TestExpectedNode;
    try testing.expectEqualStrings(":id", param.value);
    try testing.expectEqualStrings("id", param.param_name.?);
    try testing.expect(!param.is_wildcard);

    _ = try root.insert("/files/*");
    const wildcard = root.find("/files").?.children.?.get("*") orelse return error.TestExpectedNode;
    try testing.expect(wildcard.is_wildcard);
    try testing.expect(wildcard.param_name == null);
}

test "RouteTree: find is exact" {
    var root = try harness.newTree(testing.allocator);
    defer root.destroyTrieTree();
    _ = try root.insert("/api/users");
    _ = try root.insert("/a/b");
    _ = try root.insert("/user/:id");

    try testing.expectEqualStrings("users", root.find("/api/users").?.value);
    try testing.expect(root.find("/api/posts") == null);
    try testing.expect(root.find("/nope") == null);
    try testing.expect(root.find("/api/users/extra") == null);
    try testing.expectEqual(root, root.find("/").?);
    try testing.expectEqual(root, root.find("").?);
    try testing.expect(root.find("//a//b") != null);
    try testing.expect(root.find("/user/42") == null);
    try testing.expect(root.find("/user/id") != null);
}

test "RouteTree: findWithWildcard matches exact, parameter and wildcard paths" {
    var root = try harness.newTree(testing.allocator);
    defer root.destroyTrieTree();

    _ = try root.insert("/");
    _ = try root.insert("/root/route/two_subroute");
    _ = try root.insert("/root/route/one");
    const target = "/root/route/two/subroute/three";
    _ = try root.insert(target);
    _ = try root.insert("/root/route/two/subroute/four");
    _ = try root.insert("/root/route/two/subroute/five");
    _ = try root.insert("/root/route/two");
    _ = try root.insert("/root/route/one/one_subroute");
    _ = try root.insert("/products/*");
    _ = try root.insert("/orders/*/details");
    _ = try root.insert("/api/*/users/*");
    _ = try root.insert("/api/*/products/*");
    _ = try root.insert("/user/:id");
    _ = try root.insert("/anything");

    try testing.expectEqualStrings(target, root.findWithWildcard(target).?.full_path);
    try testing.expectEqualStrings("/root/route/two", root.findWithWildcard("/root/route/two").?.full_path);
    try testing.expectEqual(root, root.findWithWildcard("/").?);
    try testing.expect(root.findWithWildcard("/products/anything") != null);
    try testing.expect(root.findWithWildcard("/orders/123/details") != null);
    try testing.expect(root.findWithWildcard("/orders/456/other") != null);
    try testing.expect(root.findWithWildcard("/unknown") == null);
    try testing.expect(root.findWithWildcard("/api/v1/users/123") != null);
    try testing.expect(root.findWithWildcard("/api/v1/products/456") != null);
    try testing.expect(root.findWithWildcard("/api/v2/users/789") != null);
    try testing.expect(root.findWithWildcard("/user/42") != null);
}

test "RouteTree: routes attached to nodes" {
    var root = try harness.newTree(testing.allocator);
    defer root.destroyTrieTree();

    const node = try root.insert("/items");
    const route = try Route.create(testing.allocator, "/items", .GET, &.{harness.noopHandler});
    try node.routes.?.append(route);
    try testing.expect(node.isRouteExist(route));

    const twin = try Route.create(testing.allocator, "/items", .GET, &.{});
    defer twin.deinit();
    try testing.expect(node.isRouteExist(twin));

    const other_method = try Route.create(testing.allocator, "/items", .POST, &.{});
    defer other_method.deinit();
    try testing.expect(!node.isRouteExist(other_method));

    const other_path = try Route.create(testing.allocator, "/other", .GET, &.{});
    defer other_path.deinit();
    try testing.expect(!node.isRouteExist(other_path));

    const empty = try root.insert("/empty");
    const ghost = try Route.create(testing.allocator, "/empty", .GET, &.{});
    defer ghost.deinit();
    try testing.expect(!empty.isRouteExist(ghost));
}

test "RouteTree: getCurrentTreeRoutes and use walk the subtree" {
    var root = try harness.newTree(testing.allocator);
    defer root.destroyTrieTree();

    const a = try root.insert("/a");
    try a.routes.?.append(try Route.create(testing.allocator, "/a", .GET, &.{}));
    const b = try root.insert("/a/b");
    try b.routes.?.append(try Route.create(testing.allocator, "/a/b", .GET, &.{}));
    try b.routes.?.append(try Route.create(testing.allocator, "/a/b", .POST, &.{}));
    const other = try root.insert("/other");
    try other.routes.?.append(try Route.create(testing.allocator, "/other", .GET, &.{}));

    {
        const routes = root.getCurrentTreeRoutes();
        defer routes.deinit();
        try testing.expectEqual(@as(usize, 4), routes.items.len);
    }
    {
        const from_b = b.getCurrentTreeRoutes();
        defer from_b.deinit();
        try testing.expectEqual(@as(usize, 2), from_b.items.len);
        try testing.expectEqualStrings("/a/b", from_b.items[0].path);
    }

    try a.use(&.{harness.noopHandler});
    try testing.expectEqual(@as(usize, 1), a.routes.?.items[0].handlers.items.len);
    try testing.expectEqual(@as(usize, 1), b.routes.?.items[0].handlers.items.len);
    try testing.expectEqual(@as(usize, 0), other.routes.?.items[0].handlers.items.len);

    var bare = try harness.newTree(testing.allocator);
    defer bare.destroyTrieTree();
    _ = try bare.insert("/no/routes/here");
    const none = bare.getCurrentTreeRoutes();
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.items.len);
    try bare.use(&.{harness.noopHandler});
}

test "RouteTree: destroying a tree releases its routes" {
    var root = try harness.newTree(testing.allocator);
    const node = try root.insert("/owned");
    try node.routes.?.append(try Route.create(testing.allocator, "/owned", .GET, &.{}));
    try node.routes.?.append(try Route.create(testing.allocator, "/owned", .POST, &.{}));
    const deep = try root.insert("/owned/deep/deeper");
    try deep.routes.?.append(try Route.create(testing.allocator, "/owned/deep/deeper", .PUT, &.{}));
    root.destroyTrieTree();
}
