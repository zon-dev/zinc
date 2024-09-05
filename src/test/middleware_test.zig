// test "Middleware" {
//     var text: []const u8 = undefined;

//     var router = zinc.Router.init(.{});

//     const mid1 = struct {
//         var signature: []const u8 = undefined;
//         inline fn testMiddle1(c: *Context) anyerror!void {
//             text += "A";
//             try c.next();
//             text += "B";
//         }
//     };
//     router.use(mid1.testMiddle1);
//     // router.get("/", mid3.testMiddle3);
//     std.testing.expectEqualStrings("ACDB", signature);
// }
