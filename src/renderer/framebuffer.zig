const vk = @import("vulkan");
const ctx = @import("context.zig");

const Renderpass = @import("renderpass.zig").Renderpass;

pub const Framebuffer = struct {
    handle: vk.Framebuffer,
    attachments: []const vk.ImageView,
    renderpass: Renderpass,

    pub fn init(context: ctx.VkContext, renderpass: Renderpass, attachments: []const vk.ImageView, width: u32, height: u32) !Framebuffer {
        const create_info = vk.FramebufferCreateInfo{
            .render_pass = renderpass.handle,
            .attachment_count = @intCast(attachments.len),
            .p_attachments = @ptrCast(attachments),
            .width = width,
            .height = height,
            .layers = 1,
        };

        const handle = try context.vkd.createFramebuffer(context.dev, &create_info, context.vk_allocator);
        return Framebuffer{
            .handle = handle,
            .attachments = attachments,
            .renderpass = renderpass,
        };
    }
    pub fn deinit(self: *Framebuffer, context: ctx.VkContext) void {
        context.vkd.destroyFramebuffer(context.dev, self, context.vk_allocator);
    }
};
