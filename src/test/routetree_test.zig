const std = @import("std");

const zinc = @import("../zinc.zig");
const Route = zinc.Route;
const RouteTree = zinc.RouteTree;
const RootTree = zinc.RootTree;

fn createTree() anyerror!*RouteTree {
    const allocator = std.testing.allocator;
    var root = try RouteTree.init(.{
        .allocator = allocator,
        .children = std.StringHashMap(*RouteTree).init(allocator),
        .routes = std.ArrayList(*Route).init(allocator),
    });

    // defer root.destoryRootTree();

    // Insert values into the Route Tree
    _ = try root.insert("/");
    _ = try root.insert("/root/route/two_subroute");
    _ = try root.insert("/root/route/one");
    _ = try root.insert("/root/route/two/subroute/three");
    _ = try root.insert("/root/route/two/subroute/four");
    _ = try root.insert("/root/route/two/subroute/five");
    _ = try root.insert("/root/route/two");
    _ = try root.insert("/root/route/one/one_subroute");

    return root;
}

test "RouteTree /" {
    var root = try createTree();
    defer root.destoryRootTree();

    const path_to_find = "/root/route/two/subroute/three";
    const node = root.find(path_to_find).?;

    try std.testing.expectEqualStrings("three", node.value);

    const parent = node.getParent(); // Get the parent of the node
    try std.testing.expectEqualStrings("subroute", parent.?.value);
    const grandparent = parent.?.getParent(); // Get the grandparent of the node
    try std.testing.expectEqualStrings("two", grandparent.?.value);

    const search_value = "four";
    const found_node = root.findByValue(search_value);
    try std.testing.expect(found_node != null);
    try std.testing.expectEqualStrings(search_value, found_node.?.value);

    const four_path = found_node.?.getPath().?;
    defer found_node.?.allocator.free(four_path); // Free the memory
    try std.testing.expectEqualStrings("/root/route/two/subroute/four", four_path);

    const route_node = root.findByValue("route");
    const two = route_node.?.getChild("two");
    try std.testing.expect(two != null);
    const one = route_node.?.getChild("one");
    try std.testing.expect(one != null);
    const subroute = two.?.getChild("subroute");
    try std.testing.expect(subroute != null);
}

test "RouteTree /root/route" {
    var root = try createTree();
    defer root.destoryRootTree();

    // Find and print a specific node
    // const path_to_find = "/root/route/two/subroute/three";
    const path_to_find = "/root/route/two/subroute/three";

    const node = root.find(path_to_find).?;
    try std.testing.expectEqualStrings("three", node.value);

    const parent = node.getParent(); // Get the parent of the node
    try std.testing.expectEqualStrings("subroute", parent.?.value);
    const grandparent = parent.?.getParent(); // Get the grandparent of the node
    try std.testing.expectEqualStrings("two", grandparent.?.value);

    const node_path = node.getPath().?;
    defer node.allocator.free(node_path); // Free the memory
    try std.testing.expectEqualStrings(path_to_find, node_path);

    const search_value = "four";
    const found_node = root.findByValue(search_value);
    try std.testing.expect(found_node != null);
    try std.testing.expectEqualStrings(search_value, found_node.?.value);

    const four_path = found_node.?.getPath().?;
    defer found_node.?.allocator.free(four_path); // Free the memory
    try std.testing.expectEqualStrings("/root/route/two/subroute/four", four_path);

    const route_node = root.findByValue("route");
    const two = route_node.?.getChild("two");
    try std.testing.expect(two != null);
    const one = route_node.?.getChild("one");
    try std.testing.expect(one != null);
    const subroute = two.?.getChild("subroute");
    try std.testing.expect(subroute != null);
}
