//! Tests for `zinc.Catchers`, the status-to-handler map behind custom error
//! pages. The router consults it when a lookup fails: a `NotFound` becomes the
//! `.not_found` catcher and a `MethodNotAllowed` becomes `.method_not_allowed`.
//! With no catcher registered the error propagates to the caller.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Catchers = zinc.Catchers;
const Router = zinc.Router;
const Route = zinc.Route;
const RouteError = Route.RouteError;

const harness = @import("harness.zig");

test "Catchers: a fresh instance has no handlers" {
    var catchers = try Catchers.init(testing.allocator);
    defer catchers.deinit();

    try testing.expect(catchers.get(.not_found) == null);
    try testing.expect(catchers.get(.method_not_allowed) == null);
    try testing.expect(catchers.get(.internal_server_error) == null);
}

test "Catchers: put then get" {
    var catchers = try Catchers.init(testing.allocator);
    defer catchers.deinit();

    const handler = harness.textHandler("404 page");
    try catchers.put(.not_found, handler);

    try testing.expectEqual(handler, catchers.get(.not_found).?);
}

test "Catchers: handlers are keyed independently by status" {
    var catchers = try Catchers.init(testing.allocator);
    defer catchers.deinit();

    const not_found = harness.textHandler("404");
    const not_allowed = harness.textHandler("405");
    const server_error = harness.textHandler("500");

    try catchers.put(.not_found, not_found);
    try catchers.put(.method_not_allowed, not_allowed);
    try catchers.put(.internal_server_error, server_error);

    try testing.expectEqual(not_found, catchers.get(.not_found).?);
    try testing.expectEqual(not_allowed, catchers.get(.method_not_allowed).?);
    try testing.expectEqual(server_error, catchers.get(.internal_server_error).?);
    try testing.expect(catchers.get(.bad_request) == null);
}

test "Catchers: put replaces an existing handler" {
    var catchers = try Catchers.init(testing.allocator);
    defer catchers.deinit();

    try catchers.put(.not_found, harness.textHandler("old"));
    const replacement = harness.textHandler("new");
    try catchers.put(.not_found, replacement);

    try testing.expectEqual(replacement, catchers.get(.not_found).?);
}

test "Catchers: a stored handler runs against a context" {
    var catchers = try Catchers.init(testing.allocator);
    defer catchers.deinit();

    try catchers.put(.not_found, struct {
        fn handle(ctx: *zinc.Context) anyerror!void {
            try ctx.text("Nothing here", .{ .status = .not_found });
        }
    }.handle);

    var tc = try harness.newContext(testing.allocator, .{ .target = "/missing" });
    defer tc.deinit();

    const handler = catchers.get(.not_found) orelse return error.TestExpectedCatcher;
    try handler(tc.ctx);

    try harness.expectStatus(tc.ctx, .not_found);
    try harness.expectBody(tc.ctx, "Nothing here");
}

test "Catchers: many statuses can be registered at once" {
    var catchers = try Catchers.init(testing.allocator);
    defer catchers.deinit();

    const statuses = [_]std.http.Status{
        .bad_request,
        .unauthorized,
        .forbidden,
        .not_found,
        .method_not_allowed,
        .internal_server_error,
        .service_unavailable,
    };

    for (statuses) |status| try catchers.put(status, harness.noopHandler);
    for (statuses) |status| try testing.expect(catchers.get(status) != null);
}

// ---------------------------------------------------------------------------
// Router integration
// ---------------------------------------------------------------------------

test "Catchers: a router starts with an empty catcher set" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    try testing.expect(router.catchers != null);
    try testing.expect(router.catchers.?.get(.not_found) == null);
}

test "Catchers: without a catcher a missing route propagates NotFound" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    try router.get("/known", harness.textHandler("known"));

    var tc = try harness.newContext(testing.allocator, .{ .target = "/unknown" });
    defer tc.deinit();

    try testing.expectError(RouteError.NotFound, router.prepareContext(tc.ctx));
}

test "Catchers: without a catcher a bad method propagates MethodNotAllowed" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    try router.get("/known", harness.textHandler("known"));

    var tc = try harness.newContext(testing.allocator, .{ .method = .DELETE, .target = "/known" });
    defer tc.deinit();

    try testing.expectError(RouteError.MethodNotAllowed, router.prepareContext(tc.ctx));
}

test "Catchers: a router catcher is reachable through the router" {
    var router = try Router.init(.{ .allocator = testing.allocator });
    defer router.deinit();

    const handler = harness.textHandler("custom 404");
    try router.setCatcher(.not_found, handler);

    try testing.expectEqual(handler, router.catchers.?.get(.not_found).?);
}
