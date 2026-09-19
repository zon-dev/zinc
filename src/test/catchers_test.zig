//! `zinc.Catchers`: status-to-handler map behind custom error pages.
//! The router consults it when a lookup fails. With no catcher registered
//! the error propagates to the caller.

const std = @import("std");
const testing = std.testing;

const zinc = @import("../zinc.zig");
const Catchers = zinc.Catchers;
const RouteError = zinc.Route.RouteError;
const harness = @import("harness.zig");

test "Catchers: put, get, replace, and independent keys" {
    var catchers = try Catchers.init(testing.allocator);
    defer catchers.deinit();

    try testing.expect(catchers.get(.not_found) == null);
    try testing.expect(catchers.get(.method_not_allowed) == null);
    try testing.expect(catchers.get(.internal_server_error) == null);

    const not_found = harness.text("404");
    const not_allowed = harness.text("405");
    const server_error = harness.text("500");
    try catchers.put(.not_found, not_found);
    try catchers.put(.method_not_allowed, not_allowed);
    try catchers.put(.internal_server_error, server_error);

    try testing.expectEqual(not_found, catchers.get(.not_found).?);
    try testing.expectEqual(not_allowed, catchers.get(.method_not_allowed).?);
    try testing.expectEqual(server_error, catchers.get(.internal_server_error).?);
    try testing.expect(catchers.get(.bad_request) == null);

    const replacement = harness.text("new");
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
    try (catchers.get(.not_found).?)(tc.ctx);
    try harness.expectStatus(tc.ctx, .not_found);
    try harness.expectBody(tc.ctx, "Nothing here");
}

test "Catchers: many statuses can be registered at once" {
    var catchers = try Catchers.init(testing.allocator);
    defer catchers.deinit();
    const statuses = [_]std.http.Status{
        .bad_request, .unauthorized, .forbidden, .not_found,
        .method_not_allowed, .internal_server_error, .service_unavailable,
    };
    for (statuses) |status| try catchers.put(status, harness.noopHandler);
    for (statuses) |status| try testing.expect(catchers.get(status) != null);
}

test "Catchers: router starts empty; missing catchers propagate lookup errors" {
    var app = try harness.App.init(testing.allocator);
    defer app.deinit();
    try testing.expect(app.router.catchers != null);
    try testing.expect(app.router.catchers.?.get(.not_found) == null);

    try app.router.get("/known", harness.text("known"));
    try testing.expectError(RouteError.NotFound, app.dispatch(.{ .target = "/unknown" }));
    try testing.expectError(RouteError.MethodNotAllowed, app.dispatch(.{ .method = .DELETE, .target = "/known" }));

    const handler = harness.text("custom 404");
    try app.router.setCatcher(.not_found, handler);
    try testing.expectEqual(handler, app.router.catchers.?.get(.not_found).?);
}
