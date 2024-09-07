const std = @import("std");

const zinc = @import("../zinc.zig");
const RouteTree = zinc.RouteTree;
test {
    // Create the root of the Route Tree
    var root = try RouteTree.create(.{});

    // Insert values into the Route Tree
    try root.insert("/root/route/one_subroute");
    try root.insert("/root/route/two_subroute");
    try root.insert("/root/route/one");
    try root.insert("/root/route");
    try root.insert("/root/route/two/subroute/three");
    try root.insert("/root/route/two/subroute/four");
    try root.insert("/root/route/two/subroute/five");
    try root.insert("/root/route/two");
    try root.insert("/root/route/one/one_subroute");

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

    // var cit = root.findByValue("route").?.children.iterator();
    // while (cit.next()) |item| {
    //     std.debug.print("\nchild: {s}", .{item.key_ptr.*});
    // }

    const route_node = root.findByValue("route");
    const two = route_node.?.getChild("two");
    try std.testing.expect(two != null);
    const one = route_node.?.getChild("one");
    try std.testing.expect(one != null);
    const subroute = two.?.getChild("subroute");
    try std.testing.expect(subroute != null);
}
