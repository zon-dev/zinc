const std = @import("std");
const page_allocator = std.heap.page_allocator;
const zinc = @import("../zinc.zig");
const HandlerFn = zinc.HandlerFn;
const Route = zinc.Route;
const URL = @import("url");

pub const methodTree = struct {
    method: std.http.Method,
    root: *RouteTree,
};

const methodTrees: std.ArrayList(methodTree) = std.ArrayList(methodTree).init(page_allocator);

pub const RootTree = struct {
    trees: std.ArrayList(methodTree) = std.ArrayList(methodTree).init(page_allocator),

    pub fn init(self: RootTree) RootTree {
        const methods = &[_]std.http.Method{
            .GET,
            .POST,
            .PUT,
            .DELETE,
            .OPTIONS,
            .HEAD,
            .PATCH,
            .CONNECT,
            .TRACE,
        };
        var this = self;

        for (methods) |method| {
            const r = RouteTree.create(.{}) catch unreachable;
            const tree = methodTree{ .method = method, .root = r };
            this.trees.append(tree) catch unreachable;
        }
        return this;
    }

    pub fn get(self: *RootTree, method: std.http.Method) ?*RouteTree {
        for (self.trees.items) |tree| {
            if (tree.method == method) {
                return tree.root;
            }
        }
        return null;
    }
};

// Define the structure of a Route Tree node
pub const RouteTree = struct {
    allocator: std.mem.Allocator = page_allocator,

    value: []const u8 = "",

    parent: ?*RouteTree = null,

    children: std.StringHashMap((*RouteTree)) = undefined,

    routes: std.ArrayList(Route) = undefined,

    // Create a new node
    pub fn create(self: RouteTree) !*RouteTree {
        // value: []const u8
        const node = try self.allocator.create(RouteTree);
        node.* = RouteTree{
            .allocator = self.allocator,
            .value = self.value,
            .parent = self.parent,
            .children = std.StringHashMap(*RouteTree).init(self.allocator),
            .routes = std.ArrayList(Route).init(self.allocator),
        };
        return node;
    }

    pub fn destroy(self: *RouteTree) void {
        self.children.deinit();
        self.routes.deinit();
        self.allocator.destroy(self);
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
            if (current.children.get(segment)) |child| {
                current = child;
            } else {
                const new_node = try RouteTree.create(.{ .value = segment, .parent = current });
                try current.children.put(segment, new_node);
                current = new_node;
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

    // use middleware for this route and all its children
    pub fn use(self: *RouteTree, handlers: []const HandlerFn) anyerror!void {
        var stack = std.ArrayList(*RouteTree).init(self.allocator);
        stack.append(self) catch unreachable;

        while (stack.items.len > 0) {
            const node: *RouteTree = stack.pop();
            for (node.routes.items) |*route| try route.use(handlers);

            var iter = node.children.valueIterator();
            while (iter.next()) |child| {
                stack.append(child.*) catch unreachable;
            }
        }
    }

    // Get the parent node
    pub fn getParent(self: *RouteTree) ?*RouteTree {
        return self.parent orelse null;
    }

    // Get a child node by segment
    pub fn getChild(self: *RouteTree, segment: []const u8) ?*RouteTree {
        return self.children.get(segment) orelse null;
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
            if (current.children.get(segment)) |child| {
                current = child;
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
            var iter = node.children.valueIterator();
            while (iter.next()) |child| {
                stack.append(child.*) catch return null;
            }
        }

        return null;
    }

    // Get the path of the current node
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

    // get all routes
    pub fn getRoutes(self: *RouteTree) std.ArrayList(Route) {
        return self.routes;
    }

    pub fn getCurrentTreeRoutes(self: *RouteTree) std.ArrayList(Route) {
        var routes = std.ArrayList(Route).init(self.allocator);

        var childStack = std.ArrayList(*RouteTree).init(self.allocator);
        childStack.append(self) catch unreachable;

        while (childStack.items.len > 0) {
            const node: *RouteTree = childStack.pop();
            // append children routes to the routes
            routes.appendSlice(node.routes.items) catch unreachable;
            var iter = node.children.valueIterator();
            while (iter.next()) |child| {
                childStack.append(child.*) catch unreachable;
            }
        }

        return routes;
    }

    // Print the RouteTree
    pub fn print(self: *RouteTree, indentLevel: usize) void {
        const stdout = std.io.getStdOut().writer();

        const indentSize: usize = indentLevel * 2;
        var indentBuffer = std.ArrayList(u8).init(self.allocator);

        for (indentSize) |_| {
            indentBuffer.append(' ') catch {};
        }

        // Convert the buffer to a string
        const indentString = indentBuffer.items;

        var methods = std.ArrayList([]const u8).init(self.allocator);
        for (self.routes.items) |route| {
            const m: []const u8 = @tagName(route.method);
            methods.append(m) catch {};
        }

        // print the node. Example: "ZINC|   /  [GET, POST]"
        // if (self.value.len != 0 and methods.items.len != 0) {
        // }
        if (methods.items.len == 0) {
            stdout.print("|{s}/{s}\n", .{ indentString, self.value }) catch {};
        } else {
            stdout.print("|{s}/{s}  {s}\n", .{ indentString, self.value, methods.items }) catch {};
        }

        // Recursively print each child
        var iter = self.children.valueIterator();
        while (iter.next()) |child| {
            child.*.print(indentLevel + 1);
        }
    }
};
