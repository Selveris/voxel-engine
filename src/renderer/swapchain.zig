const std = @import("std");
const vk = @import("vulkan");

const ctx = @import("context.zig");
const img = @import("image.zig");

const logger = std.log.scoped(.swapchain);

pub const SwapchainError = error{
    Recreated,
    UnexpectedResult,
};

pub const SwapchainSupport = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    modes: []vk.PresentModeKHR,
};

pub fn Swapchain(comptime max_frames: u32) type {
    return struct {
        image_format: vk.SurfaceFormatKHR,
        present_mode: vk.PresentModeKHR,
        handle: vk.SwapchainKHR,
        images: [max_frames]vk.Image,
        image_views: [max_frames]vk.ImageView,
        min_extent: vk.Extent2D,
        max_extent: vk.Extent2D,
        image_count: u32,
        depth_image: img.Image2D,

        pub fn init(context: ctx.VkContext, support: SwapchainSupport) !Swapchain(max_frames) {
            var swapchain: Swapchain(max_frames) = undefined;

            swapchain.image_format = for (support.formats) |format| {
                if (format.format == .b8g8r8a8_unorm and format.color_space == .srgb_nonlinear_khr) {
                    break format;
                }
            } else support.formats[0];

            swapchain.present_mode = for (support.modes) |mode| {
                if (mode == .mailbox_khr) break mode;
            } else .immediate_khr;
            swapchain.min_extent = support.capabilities.min_image_extent;
            swapchain.max_extent = support.capabilities.max_image_extent;

            swapchain.image_count = std.math.clamp(max_frames, support.capabilities.min_image_count, support.capabilities.max_image_count);
            swapchain.handle = .null_handle;

            try _init(&swapchain, context);
            return swapchain;
        }
        pub fn deinit(self: @This(), context: ctx.VkContext) void {
            for (0..self.image_count) |index| {
                context.vkd.destroyImageView(context.dev, self.image_views[index], context.vk_allocator);
            }
            context.vkd.destroySwapchainKHR(context.dev, self.handle, context.vk_allocator);
        }
        pub fn recreate(self: *@This(), context: ctx.VkContext) !void {
            self.deinit(context);
            try _init(self, context);
            logger.debug("Vulkan: swapchain recreated", .{});
        }
        pub fn next_image_index(self: *@This(), context: ctx.VkContext, timeout: u64, image_available: vk.Semaphore, fence: vk.Fence) !u32 {
            const ret = context.vkd.acquireNextImageKHR(context.dev, self.handle, timeout, image_available, fence) catch |err| {
                switch (err) {
                    .OutOfDateKHR => {
                        self.recreate(context);
                        logger.info("Vulkan: Out of date swapchain, recreated it", .{});
                        return SwapchainError.Recreated;
                    },
                    else => return err,
                }
            };

            if (ret.result != .success and ret.result != .suboptimal_khr) {
                logger.warn("Vulkan: Received unexpected result for next_image_index: {any}", .{ret.result});
                return SwapchainError.UnexpectedResult;
            }
            return ret.image_index;
        }
        pub fn present(self: *@This(), context: ctx.VkContext, present_queue: vk.Queue, render_complete: vk.Semaphore, image_index: u32) !void {
            const ret = context.vkd.queuePresentKHR(present_queue, &.{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = &render_complete,
                .swapchain_count = 1,
                .p_swapchains = &self.handle,
                .p_image_indices = &image_index,
            }) catch |err| {
                switch (err) {
                    .OutOfDateKHR => {
                        self.recreate(context);
                        logger.info("Vulkan: Out of date swapchain, recreated it", .{});
                        return SwapchainError.Recreated;
                    },
                    else => return err,
                }
            };

            switch (ret) {
                .suboptimal_khr => {
                    self.recreate(context);
                    logger.info("Vulkan: Out of date swapchain, recreated it", .{});
                    return SwapchainError.Recreated;
                },
                .success => {},
                else => {
                    logger.warn("Vulkan: Received unexpected result for next_image_index: {any}", .{ret.result});
                    return SwapchainError.UnexpectedResult;
                },
            }
        }

        fn _init(self: *@This(), context: ctx.VkContext) !void {
            const extent: vk.Extent2D = .{
                .width = std.math.clamp(context.frame_width, self.min_extent.width, self.max_extent.width),
                .height = std.math.clamp(context.frame_height, self.max_extent.height, self.max_extent.height),
            };
            var create_info: vk.SwapchainCreateInfoKHR = .{
                .surface = context.surface,
                .min_image_count = self.image_count,
                .image_format = self.image_format.format,
                .image_color_space = self.image_format.color_space,
                .image_extent = extent,
                .image_array_layers = 1,
                .image_usage = .{ .color_attachment_bit = true },
                .composite_alpha = .{ .opaque_bit_khr = true },
                .present_mode = self.present_mode,
                .clipped = vk.TRUE,
                .old_swapchain = self.handle,
                .pre_transform = .{ .identity_bit_khr = true },
                .image_sharing_mode = .exclusive,
                .queue_family_index_count = 0,
                .p_queue_family_indices = null,
            };
            const family_indices = [2]u32{
                context.device_info.queues.graphics_family.items[0],
                context.device_info.queues.present_family.items[0],
            };
            if (family_indices[0] != family_indices[1]) {
                create_info.image_sharing_mode = .concurrent;
                create_info.queue_family_index_count = 2;
                create_info.p_queue_family_indices = &family_indices;
            }

            self.handle = try context.vkd.createSwapchainKHR(context.dev, &create_info, context.vk_allocator);

            const res = try context.vkd.getSwapchainImagesKHR(context.dev, self.handle, &self.image_count, &self.images);
            if (res != .success) {
                return SwapchainError.UnexpectedResult;
            }

            for (0..self.image_count) |index| {
                self.image_views[index] = try img.createImageView(self.images[index], context, .@"2d", self.image_format.format, .{ .color_bit = true });
            }
            self.depth_image = try img.Image2D.init(context, .{ .depth = 1, .height = extent.height, .width = extent.width }, context.device_info.depth_format, .optimal, .{ .depth_stencil_attachment_bit = true }, .{ .device_local_bit = true }, .{ .depth_bit = true });
        }
    };
}
