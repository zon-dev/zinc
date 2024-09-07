const std = @import("std");

// Define the structure of a Route Tree node
pub const RouteTree = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,

    value: []const u8 = "",

    parent: ?*RouteTree = null,

    children: std.StringHashMap((*RouteTree)) = std.StringHashMap(*RouteTree).init(std.heap.page_allocator),

    // Create a new node
    pub fn create(self: RouteTree) !*RouteTree {
        // value: []const u8
        const node = try self.allocator.create(RouteTree);
        node.* = RouteTree{
            .allocator = self.allocator,
            .value = self.value,
            .parent = self.parent,
            .children = self.children,
        };
        return node;
    }

    // Insert a value into the Route Tree
    pub fn insert(self: *RouteTree, value: []const u8) !void {
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

    // Find a node by its value using DFS
    pub fn findByValue(self: *RouteTree, value: []const u8) ?*RouteTree {
        // Stack for DFS traversal
        var stack = std.ArrayList(*RouteTree).init(self.allocator);
        // defer stack.deinit();
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
};
