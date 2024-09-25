const std = @import("std");
const sdl = @import("sdl2");
const vk_context = @import("renderer/context.zig");
const display = @import("./renderer/window.zig");

const App = struct {
    window: sdl.Window,
    renderer: sdl.Renderer,
    context: vk_context.VkContext,

    fn init(width: usize, height: usize) !App {
        var window = try sdl.createWindow(
            "SDL2 Wrapper Demo",
            .{ .centered = {} },
            .{ .centered = {} },
            width,
            height,
            .{ .vis = .shown, .context = .vulkan },
        );
        errdefer window.destroy();

        var sdl_display = display.SdlDisplay{ .window = window };
        const context = try vk_context.VkContext.init(null, "Spoc", sdl_display.AsWindowDisplay());
        errdefer context.deinit();

        const renderer = try sdl.createRenderer(window, null, .{ .accelerated = true });
        try renderer.setColorRGB(0x06, 0x1a, 0x20);

        return App{
            .window = window,
            .renderer = renderer,
            .context = context,
        };
    }
    fn deinit(self: *App) void {
        self.context.deinit();
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
    try sdl.init(sdl.InitFlags{ .events = true, .video = true });
    defer sdl.quit();
    var app = try App.init(920, 680);

    try app.run();
}
