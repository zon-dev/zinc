const std = @import("std");

const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const RouteTree = zinc.RouteTree;
const URL = @import("url");

fn createTree() anyerror!*RouteTree {
    const allocator = std.testing.allocator;
    const root = try RouteTree.init(.{
        .value = "/",
        .full_path = "/",
        .allocator = allocator,
        .children = std.StringHashMap(*RouteTree).init(allocator),
        .routes = std.ArrayList(*Route).init(allocator),
    });
    return root;
}

test "insert method test" {
    var root = try createTree();
    defer root.destroyTrieTree();

    // Insert a route
    const routeValue = "/test/route";
    const lastNode = try root.insert(routeValue);

    try std.testing.expectEqualStrings("route", lastNode.value);
    try std.testing.expectEqualStrings(routeValue, lastNode.full_path);
}

test "RouteTree /" {
    var root = try createTree();
    defer root.destroyTrieTree();

    // Insert values into the Route Tree
    _ = try root.insert("/");
    _ = try root.insert("/root/route/two_subroute");
    _ = try root.insert("/root/route/one");

    const path_to_find = "/root/route/two/subroute/three";
    _ = try root.insert(path_to_find);

    _ = try root.insert("/root/route/two/subroute/four");
    _ = try root.insert("/root/route/two/subroute/five");
    _ = try root.insert("/root/route/two");
    _ = try root.insert("/root/route/one/one_subroute");

    const node = root.findWithWildcard(path_to_find).?;
    try std.testing.expectEqualStrings(path_to_find, node.full_path);
    try std.testing.expectEqualStrings("three", node.value);

    const find_two = "/root/route/two";
    const find_two_node = root.findWithWildcard(find_two).?;
    try std.testing.expectEqualStrings(find_two, find_two_node.full_path);
}

test "RouteTree wildcard insert and search" {
    var routeTree = try createTree();
    defer routeTree.destroyTrieTree();

    // Insert some routes
    _ = try routeTree.insert("/products/*");
    _ = try routeTree.insert("/orders/*/details");

    // routeTree.print(1);

    {
        // Tests matches with wildcards
        try std.testing.expect(routeTree.findWithWildcard("/products/anything") != null);
        try std.testing.expect(routeTree.findWithWildcard("/orders/123/details") != null);
        try std.testing.expect(routeTree.findWithWildcard("/orders/456/other") != null);
    }

    {
        // Test for nonexistent paths
        try std.testing.expect(routeTree.findWithWildcard("/unknown") == null);

        // TODO
        // try std.testing.expect(routeTree.findWithWildcard("/products/123/details") == null);
    }
}

test "RouteTree complex wildcard match" {
    var routeTree = try createTree();
    defer routeTree.destroyTrieTree();

    // Insert complex wildcards
    _ = try routeTree.insert("/api/*/users/*");
    _ = try routeTree.insert("/api/*/products/*");

    // routeTree.print(1);

    // Test for valid matches
    const path_to_find = "/api/v1/users/123";
    try std.testing.expect(routeTree.findWithWildcard(path_to_find) != null);
    // TODO
    // const find = routeTree.findWithWildcard(path_to_find).?;
    // try std.testing.expectEqualStrings(find.full_path, path_to_find);

    try std.testing.expect(routeTree.findWithWildcard("/api/v1/products/456") != null);
    try std.testing.expect(routeTree.findWithWildcard("/api/v2/users/789") != null);

    //TODO Test for invalid paths
    // try std.testing.expect(routeTree.findWithWildcard("/api/v1/orders/123") == null);
    // try std.testing.expect(routeTree.findWithWildcard("/unknown/path") == null);
}

// test "RouteTree wildcard match multiple levels" {
//     var routeTree = try createTree();
//     defer routeTree.destroyTrieTree();

//     // insert multiple levels routes
//     _ = try routeTree.insert("/users/*/posts");
//     _ = try routeTree.insert("/users/*/comments");

//     // test multiple levels wildcard match
//     try std.testing.expect(routeTree.findWithWildcard("/users/1/posts") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/users/2/comments") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/users/3/posts") != null);

//     // test nonexistent multiple levels paths
//     try std.testing.expect(routeTree.findWithWildcard("/users/1/friends") == null);
//     try std.testing.expect(routeTree.findWithWildcard("/users/2/likes") == null);
// }

// test "RouteTree exact match" {
//     const allocator = std.heap.page_allocator;
//     var routeTree = try RouteTree.init(.{ .allocator = allocator });
//     defer routeTree.destroyTrieTree();

//     // insert specific routes
//     _ = try routeTree.insert("/home");
//     _ = try routeTree.insert("/about");

//     // test exact match
//     try std.testing.expect(routeTree.findWithWildcard("/home") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/about") != null);

//     // test nonexistent paths
//     try std.testing.expect(routeTree.findWithWildcard("/contact") == null);
// }

// test "RouteTree wildcard complex scenarios" {
//     const allocator = std.heap.page_allocator;
//     var routeTree = try RouteTree.init(allocator);
//     defer routeTree.destroy();

//     // insert complex routes
//     try routeTree.insert("/api/*/users");
//     try routeTree.insert("/api/v1/*");
//     try routeTree.insert("/files/*/documents/*");

//     // test various complex path matches
//     try std.testing.expect(routeTree.findWithWildcard("/api/v1/users") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/api/v1/products") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/api/v1/") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/files/abc/documents/123") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/files/xyz/documents/test.pdf") != null);

//     // test nonexistent complex paths
//     try std.testing.expect(routeTree.findWithWildcard("/api/v2/users") == null);
//     try std.testing.expect(routeTree.findWithWildcard("/files/abc/pictures/123") == null);
// }

// test "RouteTree wildcard mixed with exact paths" {
//     const allocator = std.heap.page_allocator;
//     var routeTree = try RouteTree.init(allocator);
//     defer routeTree.destroy();

//     // insert mixed routes
//     try routeTree.insert("/blog/*");
//     try routeTree.insert("/blog/2023");
//     try routeTree.insert("/blog/2023/post1");

//     // test exact and wildcard matches
//     try std.testing.expect(routeTree.findWithWildcard("/blog/2023") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/blog/2023/post1") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/blog/2023/anything") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/blog/anything") != null);

//     // test nonexistent paths
//     try std.testing.expect(routeTree.findWithWildcard("/blog/2024") == null);
//     try std.testing.expect(routeTree.findWithWildcard("/blog/2023/post2") == null);
// }

// test "RouteTree edge cases" {
//     const allocator = std.heap.page_allocator;
//     var routeTree = try RouteTree.init(allocator);
//     defer routeTree.destroy();

//     // insert boundary routes
//     try routeTree.insert("/"); // root path
//     try routeTree.insert("/health");
//     try routeTree.insert("/health/check");
//     try routeTree.insert("/health/*");

//     // test root path match
//     try std.testing.expect(routeTree.findWithWildcard("/") != null);

//     // test health check path
//     try std.testing.expect(routeTree.findWithWildcard("/health") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/health/check") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/health/status") != null);

//     // test nonexistent boundary paths
//     try std.testing.expect(routeTree.findWithWildcard("/unknown") == null);
// }

// test "RouteTree nested wildcards" {
//     const allocator = std.heap.page_allocator;
//     var routeTree = try RouteTree.init(allocator);
//     defer routeTree.destroy();

//     // insert nested wildcard routes
//     try routeTree.insert("/users/*/friends/*");
//     try routeTree.insert("/users/*/messages/*/details");

//     // test nested wildcard paths
//     try std.testing.expect(routeTree.findWithWildcard("/users/1/friends/2") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/users/3/messages/4/details") != null);
//     try std.testing.expect(routeTree.findWithWildcard("/users/5/messages/6/details") != null);

//     // test nonexistent nested paths
//     try std.testing.expect(routeTree.findWithWildcard("/users/1/friends/") == null);
//     try std.testing.expect(routeTree.findWithWildcard("/users/1/unknown/2") == null);
// }
