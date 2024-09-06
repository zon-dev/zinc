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
    pub fn get_parent(self: *RouteTree) ?*RouteTree {
        return self.parent orelse null;
    }

    // Get a child node by segment
    pub fn get_child(self: *RouteTree, segment: []const u8) ?*RouteTree {
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
    pub fn find_node_by_value(self: *RouteTree, value: []const u8) ?*RouteTree {
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

    // Print the tree in a structured way
    pub fn print_tree(self: *RouteTree, writer: anytype, indent: usize) !void {
        std.debug.print("calling print_tree {s}\n", .{self.value});
        try writer.print("{s}{s}\n", .{ "  ", self.value });

        var iter = self.children.valueIterator();
        while (iter.next()) |child| {
            try child.*.print_tree(writer, indent + 2);
        }
    }
    // Print all parents of the current node
    pub fn print_all_parents(self: *RouteTree, writer: anytype) !void {
        var current = self;
        while (current.parent) |parent| {
            // ignore root node
            if (parent.value.len == 0) {
                break;
            }
            try writer.print("Parent: {s}\n", .{parent.value});
            current = parent;
        }
    }

    // Get the path of the current node
    pub fn get_path(self: *RouteTree) ?[]const u8 {
        var path = std.ArrayList([]const u8).init(self.allocator);
        // defer path.deinit();

        var current = self;

        while (current.parent) |parent| {
            path.append(@constCast(current.value)) catch return null;
            current = parent;
        }

        path.append(@constCast(current.value)) catch return null; // Add the root node value

        const reversed = self.reverse(path.items);

        const full_path = std.mem.join(self.allocator, "/", reversed.items) catch return null;
        return full_path;
    }

    fn reverse(self: *RouteTree, str_arr: [][]const u8) std.ArrayList([]const u8) {
        var rev_iter = std.mem.reverseIterator(str_arr);
        var reversed_str = std.ArrayList([]const u8).init(self.allocator);
        while (rev_iter.next()) |letter| {
            reversed_str.append(letter) catch {};
        }
        return reversed_str;
    }
};
