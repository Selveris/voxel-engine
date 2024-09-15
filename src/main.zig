const std = @import("std");
const sdl = @import("sdl2");
const vk = @import("vulkan");
const loader = @import("obj_loader.zig");

pub fn main() !void {
    // var window = try sdl.createWindow(
    //     "SDL2 Wrapper Demo",
    //     .{ .centered = {} },
    //     .{ .centered = {} },
    //     640,
    //     480,
    //     .{ .vis = .shown },
    // );
    // defer window.destroy();

    // var renderer = try sdl.createRenderer(window, null, .{ .accelerated = true });
    // defer renderer.destroy();

    // mainLoop: while (true) {
    //     while (sdl.pollEvent()) |ev| {
    //         switch (ev) {
    //             .quit => break :mainLoop,
    //             else => {},
    //         }
    //     }

    //     try renderer.setColorRGB(0xF7, 0xA4, 0x1D);
    //     try renderer.clear();

    //     renderer.present();
    // }

    loader.load_obj("test");
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
