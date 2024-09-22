const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl2");

const logger = std.log.scoped(.window);

pub const WindowDisplayError = error{
    OutOfMemory,
    FailedLink,
    UnexpectedError,
};

pub const WindowDisplay = struct {
    ptr: *anyopaque,
    vtab: *const VTab,

    const VTab = struct {
        get_extensions: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) WindowDisplayError![][*:0]const u8,
        get_proc_addr: *const fn (ptr: *anyopaque) WindowDisplayError!vk.PfnGetInstanceProcAddr,
        create_surface: *const fn (ptr: *anyopaque, instance: vk.Instance) WindowDisplayError!vk.SurfaceKHR,
    };

    pub fn get_extensions(self: WindowDisplay, allocator: std.mem.Allocator) WindowDisplayError![][*:0]const u8 {
        return self.vtab.get_extensions(self.ptr, allocator);
    }
    pub fn get_proc_addr(self: WindowDisplay) WindowDisplayError!vk.PfnGetInstanceProcAddr {
        return self.vtab.get_proc_addr(self.ptr);
    }
    pub fn create_surface(self: WindowDisplay, instance: vk.Instance) WindowDisplayError!vk.SurfaceKHR {
        return self.vtab.create_surface(self.ptr, instance);
    }

    pub fn init(obj: anytype) WindowDisplay {
        const Ptr = @TypeOf(obj);
        const PtrInfo = @typeInfo(Ptr);

        std.debug.assert(PtrInfo == .Pointer);
        std.debug.assert(PtrInfo.Pointer.size == .One);
        std.debug.assert(@typeInfo(PtrInfo.Pointer.child) == .Struct);

        const impl = struct {
            fn get_extensions(ptr: *anyopaque, allocator: std.mem.Allocator) WindowDisplayError![][*:0]const u8 {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.get_extensions(allocator);
            }
            fn get_proc_addr(ptr: *anyopaque) WindowDisplayError!vk.PfnGetInstanceProcAddr {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.get_proc_addr();
            }
            fn create_surface(ptr: *anyopaque, instance: vk.Instance) WindowDisplayError!vk.SurfaceKHR {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.create_surface(instance);
            }
        };
        return .{
            .ptr = obj,
            .vtab = &.{
                .get_extensions = impl.get_extensions,
                .get_proc_addr = impl.get_proc_addr,
                .create_surface = impl.create_surface,
            },
        };
    }
};

pub const SdlDisplay = struct {
    window: sdl.Window,

    pub fn get_extensions(self: *SdlDisplay, allocator: std.mem.Allocator) WindowDisplayError![][*:0]const u8 {
        return sdl.vulkan.getInstanceExtensionsAlloc(self.window, allocator) catch |err| {
            logger.err("SDL: failed to get vulkan instance extensions: {any}", .{err});
            return WindowDisplayError.UnexpectedError;
        };
    }
    pub fn get_proc_addr(_: *SdlDisplay) WindowDisplayError!vk.PfnGetInstanceProcAddr {
        return sdl.vulkan.getVkGetInstanceProcAddr() catch |err| {
            logger.err("SDL: failed to get instance link: {any}", .{err});
            return WindowDisplayError.FailedLink;
        };
    }
    pub fn create_surface(self: *SdlDisplay, instance: vk.Instance) WindowDisplayError!vk.SurfaceKHR {
        return sdl.vulkan.createSurface(self.window, instance) catch |err| {
            logger.err("SDL: failed to create surface: {any}", .{err});
            return WindowDisplayError.UnexpectedError;
        };
    }

    pub fn AsWindowDisplay(self: *SdlDisplay) WindowDisplay {
        return WindowDisplay.init(self);
    }
};
