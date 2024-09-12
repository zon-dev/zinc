const std = @import("std");

const zinc = @import("../zinc.zig");
const RouteTree = zinc.RouteTree;
const RootTree = zinc.RootTree;

test "RouteTree /" {
    // Create the root of the Route Tree
    var root = try RouteTree.create(.{});

    // Insert values into the Route Tree
    _ = try root.insert("/");
    _ = try root.insert("/root/route/two_subroute");
    _ = try root.insert("/root/route/one");
    _ = try root.insert("/root/route/two/subroute/three");
    _ = try root.insert("/root/route/two/subroute/four");
    _ = try root.insert("/root/route/two/subroute/five");
    _ = try root.insert("/root/route/two");
    _ = try root.insert("/root/route/one/one_subroute");

    // Find and print a specific node
    // const path_to_find = "/root/route/two/subroute/three";
    const path_to_find = "/root/route/two/subroute/three";
    const node = root.find(path_to_find);
    try std.testing.expectEqualStrings("three", node.?.value);

    const parent = node.?.getParent(); // Get the parent of the node
    try std.testing.expectEqualStrings("subroute", parent.?.value);
    const grandparent = parent.?.getParent(); // Get the grandparent of the node
    try std.testing.expectEqualStrings("two", grandparent.?.value);

    const search_value = "four";
    const found_node = root.findByValue(search_value);
    try std.testing.expect(found_node != null);
    try std.testing.expectEqualStrings(search_value, found_node.?.value);

    const four_path = found_node.?.getPath().?;
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
    // Create the root of the Route Tree
    var root = try RouteTree.create(.{});

    // Insert values into the Route Tree
    _ = try root.insert("/root/route/one_subroute");
    _ = try root.insert("/root/route/two_subroute");
    _ = try root.insert("/root/route/one");
    _ = try root.insert("/root/route");
    _ = try root.insert("/root/route/two/subroute/three");
    _ = try root.insert("/root/route/two/subroute/four");
    _ = try root.insert("/root/route/two/subroute/five");
    _ = try root.insert("/root/route/two");
    _ = try root.insert("/root/route/one/one_subroute");

    // Find and print a specific node
    // const path_to_find = "/root/route/two/subroute/three";
    const path_to_find = "/root/route/two/subroute/three";
    const node = root.find(path_to_find);
    try std.testing.expectEqualStrings("three", node.?.value);

    const parent = node.?.getParent(); // Get the parent of the node
    try std.testing.expectEqualStrings("subroute", parent.?.value);
    const grandparent = parent.?.getParent(); // Get the grandparent of the node
    try std.testing.expectEqualStrings("two", grandparent.?.value);

    const search_value = "four";
    const found_node = root.findByValue(search_value);
    try std.testing.expect(found_node != null);
    try std.testing.expectEqualStrings(search_value, found_node.?.value);

    const four_path = found_node.?.getPath().?;
    try std.testing.expectEqualStrings("/root/route/two/subroute/four", four_path);

    const route_node = root.findByValue("route");
    const two = route_node.?.getChild("two");
    try std.testing.expect(two != null);
    const one = route_node.?.getChild("one");
    try std.testing.expect(one != null);
    const subroute = two.?.getChild("subroute");
    try std.testing.expect(subroute != null);
}

test "RootTree /test" {
    var root = RootTree.init(.{});
    var root_tree = root.get(.GET);
    try std.testing.expect(root_tree != null);
    _ = try root_tree.?.insert("/test");
    const found = root_tree.?.find("/test");
    try std.testing.expect(found != null);

    const not_found = root_tree.?.find("/not_found");
    try std.testing.expect(not_found == null);

    _ = try found.?.insert("/1");
    _ = try found.?.insert("/2");
    _ = try found.?.insert("/3");

    const find_one = root_tree.?.find("/test/1");
    try std.testing.expect(find_one != null);
    try std.testing.expectEqualStrings("1", find_one.?.value);

    const find_two = root_tree.?.findByValue("2");
    try std.testing.expect(find_two != null);
    const find_two_path = find_two.?.getPath().?;
    try std.testing.expectEqualStrings("/test/2", find_two_path);

    _ = try root_tree.?.insert("/test2");
    const found2 = root_tree.?.find("/test2");
    _ = try found2.?.insert("/2");
    const find_two2 = root_tree.?.findByValue("2");
    try std.testing.expect(find_two2 != null);
    const find_two2_path = find_two2.?.getPath().?;
    try std.testing.expectEqualStrings("/test2/2", find_two2_path);
}
