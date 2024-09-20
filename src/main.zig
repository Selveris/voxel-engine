const std = @import("std");
const sdl = @import("sdl2");
const vk = @import("vulkan");

const App = struct {
    window: sdl.Window,
    renderer: sdl.Renderer,

    fn init(width: usize, height: usize) !App {
        var window = try sdl.createWindow(
            "SDL2 Wrapper Demo",
            .{ .centered = {} },
            .{ .centered = {} },
            width,
            height,
            .{ .vis = .shown },
        );
        errdefer window.destroy();
        const renderer = try sdl.createRenderer(window, null, .{ .accelerated = true });
        try renderer.setColorRGB(0x06, 0x1a, 0x20);

        return App{ .window = window, .renderer = renderer };
    }
    fn deinit(self: *App) void {
        self.renderer.destroy();
        self.window.destroy();
    }

    fn run(self: *App) !void {
        while (true) {
            while (sdl.pollEvent()) |ev| {
                switch (ev) {
                    .quit => return,
                    else => {},
                }
            }

            try self.renderer.clear();
            self.renderer.present();
        }
    }
};

pub fn main() !void {
    var app = try App.init(920, 680);

    try app.run();
}
