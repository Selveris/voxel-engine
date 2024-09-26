const std = @import("std");
const vk = @import("vulkan");

const ctx = @import("context.zig");

const logger = std.log.scoped(.image);

pub const Image2D = struct {
    handle: vk.Image,
    mem: vk.DeviceMemory,
    view: vk.ImageView,
    extent: vk.Extent3D,

    pub fn init(context: ctx.VkContext, extent: vk.Extent3D, format: vk.Format, tiling: vk.ImageTiling, usage: vk.ImageUsageFlags, mem_flags: vk.MemoryPropertyFlags, aspect_flags: vk.ImageAspectFlags) !Image2D {
        const image_create_info: vk.ImageCreateInfo = .{
            .image_type = .@"2d",
            .extent = extent,
            .mip_levels = 4,
            .array_layers = 1,
            .format = format,
            .tiling = tiling,
            .initial_layout = .undefined,
            .usage = usage,
            .samples = .{ .@"1_bit" = true },
            .sharing_mode = .exclusive,
        };
        const image = try context.vkd.createImage(context.dev, &image_create_info, context.vk_allocator);
        const mem_reqs = context.vkd.getImageMemoryRequirements(context.dev, image);
        const mem_info: vk.MemoryAllocateInfo = .{
            .allocation_size = mem_reqs.size,
            .memory_type_index = try context.findMemoryTypeIndex(mem_reqs.memory_type_bits, mem_flags),
        };
        const mem = try context.vkd.allocateMemory(context.dev, &mem_info, context.vk_allocator);
        try context.vkd.bindImageMemory(context.dev, image, mem, 0);

        const view = try createImageView(image, context, .@"2d", format, aspect_flags);

        return Image2D{
            .handle = image,
            .mem = mem,
            .view = view,
            .extent = extent,
        };
    }
    pub fn deinit(self: *Image2D, context: ctx.VkContext) void {
        context.vkd.destroyImageView(context.dev, self.view, context.vk_allocator);
        context.vkd.freeMemory(context.dev, self.mem, context.vk_allocator);
        context.vkd.destroyImage(context.dev, self.handle, context.vk_allocator);
    }
};

pub fn createImageView(image: vk.Image, context: ctx.VkContext, view_type: vk.ImageViewType, format: vk.Format, aspect_flags: vk.ImageAspectFlags) !vk.ImageView {
    const view_create_info: vk.ImageViewCreateInfo = .{
        .image = image,
        .view_type = view_type,
        .format = format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = aspect_flags,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    return context.vkd.createImageView(context.dev, &view_create_info, context.vk_allocator);
}
