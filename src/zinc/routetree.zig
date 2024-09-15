const std = @import("std");
const zinc = @import("../zinc.zig");
const HandlerFn = zinc.HandlerFn;
const Route = zinc.Route;
const URL = @import("url");

// pub const RootTree = struct {};

// Define the structure of a Route Tree node
pub const RouteTree = struct {
    allocator: std.mem.Allocator,

    value: []const u8 = "",

    parent: ?*RouteTree = null,

    children: ?std.StringHashMap((*RouteTree)) = null,

    routes: ?std.ArrayList(*Route) = null,

    pub fn init(self: RouteTree) anyerror!*RouteTree {
        const node = try self.allocator.create(RouteTree);

        errdefer self.allocator.destroy(node);

        node.* = RouteTree{
            .allocator = self.allocator,
            .value = self.value,
            .parent = self.parent,
            .children = std.StringHashMap(*RouteTree).init(self.allocator),
            .routes = std.ArrayList(*Route).init(self.allocator),
        };

        return node;
    }

    pub fn destroy(self: *RouteTree) void {
        if (self.children != null) {
            self.children.?.deinit();
        }
        if (self.routes != null) {
            self.routes.?.deinit();
        }

        self.allocator.destroy(self);
    }

    pub fn destoryRootTree(self: *RouteTree) void {
        var stack = std.ArrayList(*RouteTree).init(self.allocator);
        defer stack.deinit();

        const root = self.getRoot() orelse self;

        // deinit all routes
        const routes = root.getCurrentTreeRoutes();
        for (routes.items) |route| route.deinit();
        routes.deinit();

        stack.append(root) catch unreachable;

        while (stack.items.len > 0) {
            var node: *RouteTree = stack.pop();

            var iter = node.children.?.valueIterator();
            while (iter.next()) |child| {
                const c: *RouteTree = child.*;
                stack.append(c) catch unreachable;
            }

            node.destroy();
        }
    }

    pub fn isRouteExist(self: *RouteTree, route: *Route) bool {
        if (self.routes != null) {
            for (self.routes.?.items) |r| {
                if (r == route) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Insert a value into the Route Tree.
    /// Return the last node of the inserted value
    pub fn insert(self: *RouteTree, value: []const u8) anyerror!*RouteTree {
        var current = self;

        // Split the value into segments
        var segments = std.mem.splitSequence(u8, value, "/");
        // Insert each segment into the tree
        while (segments.next()) |segment| {
            if (segment.len == 0) {
                continue;
            }
            // Check if child already exists
            if (current.children) |children| {
                if (children.get(segment)) |child| {
                    current = child;
                } else {
                    // Create a new child node
                    const child = try RouteTree.init(.{
                        .allocator = self.allocator,
                        .value = segment,
                        .parent = current,
                        .children = std.StringHashMap(*RouteTree).init(self.allocator),
                        .routes = std.ArrayList(*Route).init(self.allocator),
                    });
                    try current.children.?.put(segment, child);
                    current = child;
                }
            }
        }

        return current;
    }

    // get root node
    pub fn getRoot(self: *RouteTree) ?*RouteTree {
        var current = self;
        while (current.parent) |parent| {
            current = parent;
        }
        return current;
    }

    pub fn allNode(self: *RouteTree) std.ArrayList(*RouteTree) {
        var stack = std.ArrayList(*RouteTree).init(self.allocator);
        stack.append(self) catch unreachable;

        while (stack.items.len > 0) {
            const node: *RouteTree = stack.pop();
            var iter = node.children.valueIterator();
            while (iter.next()) |child| {
                stack.append(child.*) catch unreachable;
            }
        }

        return stack;
    }

    // use middleware for this route and all its children
    pub fn use(self: *RouteTree, handlers: []const HandlerFn) anyerror!void {
        var stack = std.ArrayList(*RouteTree).init(self.allocator);
        defer stack.deinit();

        stack.append(self) catch unreachable;

        while (stack.items.len > 0) {
            const node: *RouteTree = stack.pop();

            if (node.routes != null) {
                for (node.routes.?.items) |route| {
                    route.use(handlers) catch {};
                }
            }

            if (node.children == null) {
                continue;
            }

            if (node.children.?.count() == 0) {
                continue;
            }

            var iter = node.children.?.valueIterator();
            while (iter.next()) |child| {
                stack.append(child.*) catch {};
            }
        }
    }

    // Get the parent node
    pub fn getParent(self: *RouteTree) ?*RouteTree {
        return self.parent orelse null;
    }

    // Get a child node by segment
    pub fn getChild(self: *RouteTree, segment: []const u8) ?*RouteTree {
        return self.children.?.get(segment) orelse null;
    }

    // Find a node by path
    pub fn find(self: *RouteTree, path: []const u8) ?*RouteTree {
        var segments = std.mem.splitSequence(u8, path, "/"); // Example: split by slash, adjust as needed

        var current = self;

        while (segments.next()) |segment| {
            if (segment.len == 0) {
                continue;
            }
            // Check if the child node exists
            if (current.children) |children| {
                if (children.get(segment)) |child| {
                    current = child;
                } else {
                    return null; // Node not found
                }
            } else {
                return null; // Node not found
            }
        }
        return current; // Return the found node
    }

    // Find a node by its value using Depth-First Search (DFS)
    pub fn findByValue(self: *RouteTree, value: []const u8) ?*RouteTree {
        // Stack for DFS traversal
        var stack = std.ArrayList(*RouteTree).init(self.allocator);
        defer stack.deinit();
        stack.append(self) catch return null;

        while (stack.items.len > 0) {
            const node = stack.pop();
            if (std.mem.eql(u8, node.value, value)) {
                return node;
            }
            var iter = node.children.?.valueIterator();
            while (iter.next()) |child| {
                stack.append(child.*) catch return null;
            }
        }

        return null;
    }

    /// Return the path of the current node as a string.
    /// Make sure to free the string after use. route_tree.allocator.free(path);
    /// Return null if an error occurs.
    pub fn getPath(self: *RouteTree) ?[]const u8 {
        var path = std.ArrayList([]const u8).init(self.allocator);
        defer path.deinit();

        var current = self;

        while (current.parent) |parent| {
            path.append(@constCast(current.value)) catch return null;
            current = parent;
        }

        path.append(@constCast(current.value)) catch return null; // Add the root node value

        const reversed = path.items;
        std.mem.reverse([]const u8, reversed);

        return std.mem.join(self.allocator, "/", reversed) catch return null;
    }

    /// Get all routes in the current tree and its children
    /// Return a list of routes
    /// Make sure to deinit the list after use.
    /// routes.deinit();
    pub fn getCurrentTreeRoutes(self: *RouteTree) std.ArrayList(*Route) {
        var routes = std.ArrayList(*Route).init(self.allocator);
        var childStack = std.ArrayList(*RouteTree).init(self.allocator);
        defer {
            childStack.deinit();
        }

        childStack.append(self) catch unreachable;

        while (childStack.items.len > 0) {
            const node: *RouteTree = childStack.pop();

            // append children routes to the routes
            if (node.routes != null) {
                const node_routes = node.routes.?.items;

                routes.appendSlice(node_routes) catch continue;

                if (node.children != null) {
                    var iter = node.children.?.valueIterator();

                    while (iter.next()) |child| {
                        const c: *RouteTree = child.*;
                        childStack.append(c) catch unreachable;
                    }
                }
            }
        }
        return routes;
    }

    /// Print the RouteTree
    /// This is a helper function for debugging
    /// | /  [GET]        (path: /)
    /// |   /test  [GET]  (path: /test)
    /// |     /1  [GET]   (path: /test/1)
    /// |     /2  [GET]   (path: /test/2)
    /// |       /3  [GET] (path: /test/2/3)
    /// |         /4  [GET] (path: /test/2/3/4)
    pub fn print(self: *RouteTree, indentLevel: usize) void {
        const stdout = std.io.getStdOut().writer();

        const indentSize: usize = indentLevel * 2;
        var indentBuffer = std.ArrayList(u8).init(self.allocator);

        defer self.allocator.free(indentBuffer.items);

        for (indentSize) |_| {
            indentBuffer.append(' ') catch {};
        }

        // Convert the buffer to a string
        const indentString = indentBuffer.items;

        var methods = std.ArrayList([]const u8).init(self.allocator);
        if (self.routes != null) {
            for (self.routes.?.items) |route| {
                const m: []const u8 = @tagName(route.method);
                methods.append(m) catch {};
            }
        }

        if (self.value.len == 0) {
            stdout.print("|{s}ROOT\n", .{indentString}) catch {};
        } else if (methods.items.len == 0) {
            stdout.print("|{s}/{s}\n", .{ indentString, self.value }) catch {};
        } else {
            stdout.print("|{s}/{s}  {s}\n", .{ indentString, self.value, methods.items }) catch {};
        }

        if (self.children != null) {
            // Recursively print each child
            var iter = self.children.?.valueIterator();
            while (iter.next()) |child| {
                child.*.print(indentLevel + 1);
            }
        }
    }
};
