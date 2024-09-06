const std = @import("std");
const URL = @import("url");
const RespondOptions = std.http.Server.Request.RespondOptions;
const Header = std.http.Header;

const zinc = @import("../zinc.zig");
const Request = zinc.Request;
const Response = zinc.Response;
const Config = zinc.Config;
const Headers = zinc.Headers;
const Param = zinc.Param;
const HandlerFn = zinc.HandlerFn;
const Context = zinc.Context;

const RouteTree = zinc.RouteTree;
test {
    // Create the root of the Route Tree
    var root = try RouteTree.create(.{});

    // Insert values into the Route Tree
    try root.insert("/root/route/one_subroute");
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

    const parent = node.?.get_parent();
    try std.testing.expectEqualStrings("subroute", parent.?.value);
    const grandparent = parent.?.get_parent();
    try std.testing.expectEqualStrings("two", grandparent.?.value);

    const search_value = "four";
    const found_node = root.find_node_by_value(search_value);
    try std.testing.expect(found_node != null);
    try std.testing.expectEqualStrings(search_value, found_node.?.value);

    const four_path = found_node.?.get_path().?;
    try std.testing.expectEqualStrings("/root/route/two/subroute/four", four_path);
}
