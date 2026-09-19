//! Tests for `RouteTree`, the trie the router stores routes in.
//!
//! Terminology: `insert` splits a path on `/` and creates one node per
//! segment, treating `:name` as a named parameter and `*` as a wildcard.
//! `find` is an exact-match lookup; `findWithWildcard` also traverses
//! parameter and wildcard nodes.
//!
//! Not covered here, because they do not currently compile when referenced:
//! `getChild` (missing return on the null-children branch), `allNode` and
//! `matchWildcard` (both use the pre-0.15 `std.ArrayList` API). They are
//! reported separately rather than tested.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const RouteTree = zinc.RouteTree;
const HandlerFn = zinc.HandlerFn;

const harness = @import("harness.zig");

fn newTree() !*RouteTree {
    return RouteTree.init(.{
        .value = "/",
        .full_path = "/",
        .allocator = testing.allocator,
        .children = std.StringHashMap(*RouteTree).init(testing.allocator),
        .routes = std.array_list.Managed(*Route).init(testing.allocator),
    });
}

// ---------------------------------------------------------------------------
// Insert
// ---------------------------------------------------------------------------

test "RouteTree: a fresh tree is an empty root" {
    var root = try newTree();
    defer root.destroyTrieTree();

    try testing.expectEqualStrings("/", root.value);
    try testing.expectEqualStrings("/", root.full_path);
    try testing.expectEqual(@as(u32, 0), root.children.?.count());
    try testing.expectEqual(@as(usize, 0), root.routes.?.items.len);
}

test "RouteTree: insert returns the leaf node" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const leaf = try root.insert("/test/route");

    try testing.expectEqualStrings("route", leaf.value);
    try testing.expectEqualStrings("/test/route", leaf.full_path);
}

test "RouteTree: inserting the root returns the root itself" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const node = try root.insert("/");

    try testing.expectEqual(root, node);
    try testing.expectEqual(@as(u32, 0), root.children.?.count());
}

test "RouteTree: insert creates one node per segment" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/a/b/c");

    const a = root.find("/a") orelse return error.TestExpectedNode;
    try testing.expectEqualStrings("a", a.value);
    const b = root.find("/a/b") orelse return error.TestExpectedNode;
    try testing.expectEqualStrings("b", b.value);
    const c = root.find("/a/b/c") orelse return error.TestExpectedNode;
    try testing.expectEqualStrings("c", c.value);
}

test "RouteTree: inserting the same path twice reuses nodes" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const first = try root.insert("/dup/path");
    const second = try root.insert("/dup/path");

    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(u32, 1), root.children.?.count());
}

test "RouteTree: sibling paths share a common prefix" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/shared/one");
    _ = try root.insert("/shared/two");

    const shared = root.find("/shared") orelse return error.TestExpectedNode;
    try testing.expectEqual(@as(u32, 2), shared.children.?.count());
    try testing.expect(root.find("/shared/one") != null);
    try testing.expect(root.find("/shared/two") != null);
}

test "RouteTree: insert handles a single segment" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const leaf = try root.insert("/single");

    try testing.expectEqualStrings("single", leaf.value);
    try testing.expectEqual(@as(u32, 1), root.children.?.count());
}

test "RouteTree: insert tolerates a path without a leading slash" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const leaf = try root.insert("noslash");

    try testing.expectEqualStrings("noslash", leaf.value);
}

test "RouteTree: insert records a named parameter" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/user/:id");

    const user = root.find("/user") orelse return error.TestExpectedNode;
    // Parameter nodes are keyed by the bare name, not the `:name` form.
    const param = user.children.?.get("id") orelse return error.TestExpectedNode;
    try testing.expectEqualStrings(":id", param.value);
    try testing.expectEqualStrings("id", param.param_name.?);
    try testing.expect(!param.is_wildcard);
}

test "RouteTree: insert records a wildcard" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/files/*");

    const files = root.find("/files") orelse return error.TestExpectedNode;
    const wildcard = files.children.?.get("*") orelse return error.TestExpectedNode;
    try testing.expect(wildcard.is_wildcard);
    try testing.expect(wildcard.param_name == null);
}

test "RouteTree: a deeply nested path inserts cleanly" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/a/b/c/d/e/f/g/h");

    try testing.expect(root.find("/a/b/c/d/e/f/g/h") != null);
}

// ---------------------------------------------------------------------------
// find — exact matching
// ---------------------------------------------------------------------------

test "RouteTree: find locates an inserted path" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/api/users");

    const node = root.find("/api/users") orelse return error.TestExpectedNode;
    try testing.expectEqualStrings("users", node.value);
}

test "RouteTree: find returns null for an unknown path" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/api/users");

    try testing.expect(root.find("/api/posts") == null);
    try testing.expect(root.find("/nope") == null);
    try testing.expect(root.find("/api/users/extra") == null);
}

test "RouteTree: find on the root path returns the root" {
    var root = try newTree();
    defer root.destroyTrieTree();

    try testing.expectEqual(root, root.find("/").?);
    try testing.expectEqual(root, root.find("").?);
}

test "RouteTree: find ignores repeated slashes" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/a/b");

    // Empty segments are skipped during traversal.
    try testing.expect(root.find("//a//b") != null);
}

test "RouteTree: find does not traverse parameter nodes" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/user/:id");

    // `find` is exact; matching `/user/42` is `findWithWildcard`'s job.
    try testing.expect(root.find("/user/42") == null);
    try testing.expect(root.find("/user/id") != null);
}

// ---------------------------------------------------------------------------
// findWithWildcard
// ---------------------------------------------------------------------------

test "RouteTree: findWithWildcard locates an exact path" {
    var root = try newTree();
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

    const node = root.findWithWildcard(target) orelse return error.TestExpectedNode;
    try testing.expectEqualStrings(target, node.full_path);
    try testing.expectEqualStrings("three", node.value);

    const two = root.findWithWildcard("/root/route/two") orelse return error.TestExpectedNode;
    try testing.expectEqualStrings("/root/route/two", two.full_path);
}

test "RouteTree: findWithWildcard returns the root for /" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/anything");

    try testing.expectEqual(root, root.findWithWildcard("/").?);
}

test "RouteTree: findWithWildcard matches through a wildcard segment" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/products/*");
    _ = try root.insert("/orders/*/details");

    try testing.expect(root.findWithWildcard("/products/anything") != null);
    try testing.expect(root.findWithWildcard("/orders/123/details") != null);
    try testing.expect(root.findWithWildcard("/orders/456/other") != null);
}

test "RouteTree: findWithWildcard returns null for an unrelated path" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/products/*");

    try testing.expect(root.findWithWildcard("/unknown") == null);
}

test "RouteTree: findWithWildcard matches multi-level wildcards" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/api/*/users/*");
    _ = try root.insert("/api/*/products/*");

    try testing.expect(root.findWithWildcard("/api/v1/users/123") != null);
    try testing.expect(root.findWithWildcard("/api/v1/products/456") != null);
    try testing.expect(root.findWithWildcard("/api/v2/users/789") != null);
}

test "RouteTree: findWithWildcard matches a named parameter" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/user/:id");

    try testing.expect(root.findWithWildcard("/user/42") != null);
}

// ---------------------------------------------------------------------------
// Routes attached to nodes
//
// A node owns the routes appended to it: `destroyTrieTree` deinits them, so
// these tests must not also free them.
// ---------------------------------------------------------------------------

test "RouteTree: isRouteExist finds a route by method and path" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const node = try root.insert("/items");
    const route = try Route.create(testing.allocator, "/items", .GET, &.{harness.noopHandler});
    try node.routes.?.append(route);

    try testing.expect(node.isRouteExist(route));
}

test "RouteTree: isRouteExist compares by value, not identity" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const node = try root.insert("/items");
    const route = try Route.create(testing.allocator, "/items", .GET, &.{});
    try node.routes.?.append(route);

    // A separate route with the same method and path counts as existing.
    const twin = try Route.create(testing.allocator, "/items", .GET, &.{});
    defer twin.deinit();
    try testing.expect(node.isRouteExist(twin));

    // Different method, same path: not the same route.
    const other_method = try Route.create(testing.allocator, "/items", .POST, &.{});
    defer other_method.deinit();
    try testing.expect(!node.isRouteExist(other_method));

    // Same method, different path.
    const other_path = try Route.create(testing.allocator, "/other", .GET, &.{});
    defer other_path.deinit();
    try testing.expect(!node.isRouteExist(other_path));
}

test "RouteTree: isRouteExist is false on a node with no routes" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const node = try root.insert("/empty");
    const route = try Route.create(testing.allocator, "/empty", .GET, &.{});
    defer route.deinit();

    try testing.expect(!node.isRouteExist(route));
}

test "RouteTree: getCurrentTreeRoutes collects routes from the whole subtree" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const a = try root.insert("/a");
    try a.routes.?.append(try Route.create(testing.allocator, "/a", .GET, &.{}));

    const b = try root.insert("/a/b");
    try b.routes.?.append(try Route.create(testing.allocator, "/a/b", .GET, &.{}));
    try b.routes.?.append(try Route.create(testing.allocator, "/a/b", .POST, &.{}));

    const routes = root.getCurrentTreeRoutes();
    defer routes.deinit();

    try testing.expectEqual(@as(usize, 3), routes.items.len);
}

test "RouteTree: getCurrentTreeRoutes is empty for a bare tree" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/no/routes/here");

    const routes = root.getCurrentTreeRoutes();
    defer routes.deinit();

    try testing.expectEqual(@as(usize, 0), routes.items.len);
}

test "RouteTree: getCurrentTreeRoutes from a subtree excludes ancestors" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const a = try root.insert("/a");
    try a.routes.?.append(try Route.create(testing.allocator, "/a", .GET, &.{}));

    const b = try root.insert("/a/b");
    try b.routes.?.append(try Route.create(testing.allocator, "/a/b", .GET, &.{}));

    const from_b = b.getCurrentTreeRoutes();
    defer from_b.deinit();

    try testing.expectEqual(@as(usize, 1), from_b.items.len);
    try testing.expectEqualStrings("/a/b", from_b.items[0].path);
}

test "RouteTree: use appends middleware to every route in the subtree" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const a = try root.insert("/a");
    try a.routes.?.append(try Route.create(testing.allocator, "/a", .GET, &.{}));
    const b = try root.insert("/a/b");
    try b.routes.?.append(try Route.create(testing.allocator, "/a/b", .GET, &.{}));

    try root.use(&.{harness.noopHandler});

    try testing.expectEqual(@as(usize, 1), a.routes.?.items[0].handlers.items.len);
    try testing.expectEqual(@as(usize, 1), b.routes.?.items[0].handlers.items.len);
}

test "RouteTree: use on a tree with no routes is harmless" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/a/b/c");

    try root.use(&.{harness.noopHandler});
}

test "RouteTree: use only affects the subtree it is called on" {
    var root = try newTree();
    defer root.destroyTrieTree();

    const a = try root.insert("/a");
    try a.routes.?.append(try Route.create(testing.allocator, "/a", .GET, &.{}));
    const other = try root.insert("/other");
    try other.routes.?.append(try Route.create(testing.allocator, "/other", .GET, &.{}));

    try a.use(&.{harness.noopHandler});

    try testing.expectEqual(@as(usize, 1), a.routes.?.items[0].handlers.items.len);
    try testing.expectEqual(@as(usize, 0), other.routes.?.items[0].handlers.items.len);
}

test "RouteTree: destroying a tree releases its routes" {
    // The testing allocator turns any missed free into a test failure.
    var root = try newTree();

    const node = try root.insert("/owned");
    try node.routes.?.append(try Route.create(testing.allocator, "/owned", .GET, &.{}));
    try node.routes.?.append(try Route.create(testing.allocator, "/owned", .POST, &.{}));

    const deep = try root.insert("/owned/deep/deeper");
    try deep.routes.?.append(try Route.create(testing.allocator, "/owned/deep/deeper", .PUT, &.{}));

    root.destroyTrieTree();
}

test "RouteTree: print walks the tree without crashing" {
    var root = try newTree();
    defer root.destroyTrieTree();

    _ = try root.insert("/test");

    // `print` writes to stderr, which would interleave with the test runner's
    // output, so only the tree construction is exercised here. Enable the call
    // locally when debugging a routing problem.
    // root.print(0);
}
