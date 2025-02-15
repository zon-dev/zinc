const std = @import("std");
const zinc = @import("../zinc.zig");
const HandlerFn = zinc.HandlerFn;
const Route = zinc.Route;
const URL = @import("url");

// Define the structure of a Route Tree node
pub const RouteTree = struct {
    allocator: std.mem.Allocator,

    value: []const u8, // The value of the node

    full_path: []const u8, // The full path of the node

    children: ?std.StringHashMap(*RouteTree) = null,

    routes: ?std.ArrayList(*Route) = null,

    is_wildcard: bool = false, // To mark if this node is a wildcard (like `*`)
    param_name: ?[]const u8 = null, // To store the parameter name (like `:name`)

    pub fn init(self: RouteTree) anyerror!*RouteTree {
        const node = try self.allocator.create(RouteTree);

        errdefer self.allocator.destroy(node);

        node.* = RouteTree{
            .value = self.value,
            .full_path = self.full_path,
            .allocator = self.allocator,
            .children = std.StringHashMap(*RouteTree).init(self.allocator),
            .routes = std.ArrayList(*Route).init(self.allocator),
        };

        return node;
    }

    /// Destroy the RouteTree and free memory
    pub fn destroy(self: *RouteTree) void {
        if (self.children != null) {
            self.children.?.deinit();
        }

        if (self.routes != null) {
            self.routes.?.deinit();
        }

        // self.allocator.free(self.full_path);

        self.allocator.destroy(self);
    }

    pub fn destroyTrieTree(self: *RouteTree) void {
        var stack = std.ArrayList(*RouteTree).init(self.allocator);
        defer stack.deinit();

        const routes = self.getCurrentTreeRoutes();
        defer routes.deinit();
        for (routes.items) |route| route.deinit();

        stack.append(self) catch unreachable;

        while (stack.items.len > 0) {
            var node: *RouteTree = stack.pop().?;
            defer node.destroy();

            if (node.children != null) {
                var iter = node.children.?.valueIterator();
                while (iter.next()) |child| {
                    const c: *RouteTree = child.*;
                    stack.append(c) catch unreachable;
                }
            }
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
    pub fn insert(self: *RouteTree, path: []const u8) anyerror!*RouteTree {
        var current = self;
        var start: usize = 0;
        if (std.mem.eql(u8, "/", path)) {
            return current;
        }

        var value = path;

        if (path[0] == '/') {
            value = path[1..];
        }

        // ignore / at the beginning
        for (value, 0..) |c, i| {
            if (c == '/') {
                if (i == start) {
                    continue;
                }

                const segment = value[start..i];
                const full_path = path[0 .. i + 1];
                current = try current.handleSegment(segment, full_path);
                start = i + 1;
            }
        }

        // Handle the last segment after the loop
        if (start < value.len) {
            const last_segment = value[start..]; // Get the last segment
            const full_path = path[0 .. start + last_segment.len + 1]; // Get the full path
            current = try current.handleSegment(last_segment, full_path); // Insert the last segment
        }

        return current; // Return the last node of the inserted value
    }

    /// Handle the insertion of an individual path segment
    fn handleSegment(self: *RouteTree, segment: []const u8, full_path: []const u8) !*RouteTree {
        var next_node: ?*RouteTree = null;

        switch (segment[0]) {
            '*' => {
                // Wildcard segment (e.g., "*")
                next_node = self.children.?.get("*");
                if (next_node == null) {
                    next_node = try self.createChild(segment, full_path, true, null);
                }
            },
            ':' => {
                // Named parameter segment (e.g., ":param")
                const param_name = segment[1..];
                next_node = self.children.?.get(param_name);
                if (next_node == null) {
                    next_node = try self.createChild(segment, full_path, false, param_name);
                }
            },
            else => {
                // Regular path segment
                next_node = self.children.?.get(segment);
                if (next_node == null) {
                    next_node = try self.createChild(segment, full_path, false, null);
                }
            },
        }

        return next_node.?;
    }

    /// Create a child node in the RouteTree
    fn createChild(self: *RouteTree, segment: []const u8, full_path: []const u8, is_wildcard: bool, param_name: ?[]const u8) anyerror!*RouteTree {
        const allocator = self.allocator;

        const new_node = try allocator.create(RouteTree);
        new_node.* = RouteTree{
            .value = segment,
            .full_path = full_path,
            .allocator = allocator,
            .children = std.StringHashMap(*RouteTree).init(allocator),
            .routes = std.ArrayList(*Route).init(allocator),
            .is_wildcard = is_wildcard,
            .param_name = param_name orelse null,
        };

        // Insert the new node into the current node's children
        if (is_wildcard) {
            try self.children.?.put("*", new_node);
        } else if (param_name) |name| {
            try self.children.?.put(name, new_node);
        } else {
            try self.children.?.put(segment, new_node);
        }

        return new_node;
    }

    fn chooseNextChild(self: *RouteTree, segment: []const u8) ?*RouteTree {
        // Check for exact match
        if (self.children.?.get(segment)) |child| {
            return child;
        }

        // Check for named parameter (i.e., ":param")
        var it = self.children.?.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, ":")) {
                return entry.value_ptr.*;
            }
        }

        // Check for wildcard match
        if (self.children.?.get("*")) |wildcard_child| {
            return wildcard_child;
        }

        // No match found
        return null;
    }

    //     return current; // Return the found node
    // }

    // Matches wildcards
    fn matchWildcard(self: *RouteTree) ?*RouteTree {
        var result = std.ArrayList(*RouteTree).init(self.allocator);
        defer result.deinit();

        var stack = std.ArrayList(*RouteTree).init(self.allocator);
        defer stack.deinit();

        stack.append(self) catch unreachable;

        while (stack.items.len > 0) {
            const node: *RouteTree = stack.pop();

            // 如果当前节点是路由的结尾，添加到结果
            if (node.routes != null and node.routes.?.items.len > 0) {
                result.append(node) catch continue;
            } // 将所有子节点添加到栈中
            if (node.children != null) {
                var iter = node.children.?.valueIterator();
                while (iter.next()) |child| {
                    stack.append(child.*) catch unreachable;
                }
            }
        }

        // 返回找到的所有节点（可以根据需求返回特定的节点）
        // if (result.items.len > 0) return result.items[0] orelse return null;
        return result.items[0];
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

    // Get a child node by segment
    pub fn getChild(self: *RouteTree, segment: []const u8) ?*RouteTree {
        if (self.children) |children| return children.get(segment);
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

    pub fn findWithWildcard(self: *RouteTree, path: []const u8) ?*RouteTree {
        var current = self;

        if (std.mem.eql(u8, "/", path)) {
            return current; // Root path
        }

        var start: usize = 0;
        while (start < path.len) {
            const slash_index = std.mem.indexOf(u8, path[start..], "/") orelse path.len;
            const next_slash = slash_index + start;

            var segment: []const u8 = undefined;
            // handler the last segment
            if ((slash_index == 0 and start > 0) or next_slash > path.len) {
                segment = path[start..];
            } else {
                segment = path[start..next_slash];
            }

            if (segment.len == 0) {
                start += 1; // Skip multiple slashes
                continue;
            }

            // const count = current.children.?.count();

            // Traverse the Trie based on wildcard, parameter, or exact match
            if (current.is_wildcard or (current.param_name != null)) {
                // Match wildcard segment
                var cit = current.children.?.valueIterator();
                const cit_value = cit.next() orelse return null; // Move to next child
                current = cit_value.*;
            } else if (current.children.?.get(segment)) |next_node| {
                current = next_node; // Move to the matching child
            }

            start = next_slash + 1; // Move to the next segment
        }

        if (std.mem.eql(u8, current.value, self.value)) {
            return null;
        }

        // return if (current.is_end) current else null; // Return found node or null if not a complete path
        return current; // Return found node or null if not a complete path
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
            const node: *RouteTree = childStack.pop().?;

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
        // const stdout = std.io.getStdOut().writer();

        const indentSize: usize = indentLevel * 2;
        var indentBuffer = std.ArrayList(u8).init(self.allocator);
        defer indentBuffer.deinit();

        for (0..indentSize) |_| {
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

        if (self.value.len == 0 or std.mem.eql(u8, self.value, "/")) {
            // Root node
            std.debug.print("\n----------------\n", .{});
            std.debug.print("|{s}{s} \n", .{ indentString, self.value });
        } else if (methods.items.len == 0) {
            std.debug.print("|{s}{s}  | {s} \n", .{ indentString, self.value, self.full_path });
        } else {
            std.debug.print("|{s}{s} | {s} |methods:{s}\n", .{ indentString, self.value, self.full_path, methods.items });
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
