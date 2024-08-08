const std = @import("std");
const print = std.debug.print;

// fn arena_allocator() std.heap.Allocator {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const gpa_allocator = gpa.allocator();
//     const arena = std.heap.ArenaAllocator.init(gpa_allocator);

//     defer {
//         const deinit_status = gpa.deinit();
//         if (deinit_status == .leak) @panic("Memory leak!");
//         defer arena.deinit();
//     }

//     const allocator = arena.allocator();
//     return allocator;
// }
