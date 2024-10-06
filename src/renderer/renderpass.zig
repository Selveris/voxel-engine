const vk = @import("vulkan");
const math = @import("../math.zig");
const ctx = @import("context.zig");
const cmd = @import("command.zig");

const Vec4 = math.Vec4(f32);

pub const RenderpassState = enum {
    ready,
    recording,
    rendering,
    rendered,
    submitted,
};

pub const Renderpass = struct {
    handle: vk.RenderPass,
    state: RenderpassState,
    area: vk.Rect2D,
    clear_color: Vec4,
    depth: f32,
    stencil: u32,

    pub fn init(context: ctx.VkContext, area: vk.Rect2D, clear_color: Vec4, depth: f32, stencil: u32) !Renderpass {
        const color_attachment: vk.AttachmentDescription = .{
            .format = context.swapchain.image_format.format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        };
        const depth_attachment: vk.AttachmentDescription = .{
            .format = context.device_info.depth_format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .depth_stencil_attachment_optimal,
        };
        const attachment_descriptions = [2]vk.AttachmentDescription{ color_attachment, depth_attachment };
        const color_attachment_ref: vk.AttachmentReference = .{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        };
        const depth_attachment_ref: vk.AttachmentReference = .{
            .attachment = 1,
            .layout = .depth_stencil_attachment_optimal,
        };

        const subpass: vk.SubpassDescription = .{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment_ref),
            .p_depth_stencil_attachment = @ptrCast(&depth_attachment_ref),
        };

        const dep: vk.SubpassDependency = .{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_access_mask = .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
        };

        const create_info: vk.RenderPassCreateInfo = .{
            .attachment_count = attachment_descriptions.len,
            .p_attachments = @ptrCast(&attachment_descriptions),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 1,
            .p_dependencies = @ptrCast(&dep),
        };
        const handle = try context.vkd.createRenderPass(context.dev, &create_info, context.vk_allocator);

        return Renderpass{
            .handle = handle,
            .state = RenderpassState.ready,
            .area = area,
            .clear_color = clear_color,
            .depth = depth,
            .stencil = stencil,
        };
    }
    pub fn deinit(self: *Renderpass, context: *ctx.VkContext) void {
        context.vkd.destroyRenderPass(context.dev, self.handle, context.vk_allocator);
    }

    pub fn beginInfo(self: *Renderpass, frame_buffer: vk.Framebuffer) vk.RenderPassBeginInfo {
        const clear_values: [2]vk.ClearValue = .{
            .{ .color = .{ .float_32 = self.clear_color.inner } },
            .{ .depth_stencil = .{ .depth = self.depth, .stencil = self.stencil } },
        };
        return vk.RenderPassBeginInfo{
            .render_pass = self.handle,
            .framebuffer = frame_buffer,
            .render_area = self.area,
            .clear_value_count = 2,
            .p_clear_values = clear_values,
        };
        // cmd_buffer.beginRenderpass(context, &begin_info);
    }

    // pub fn end(self: *Renderpass, context: ctx.VkContext, cmd_buffer: cmd.CommandBuffer) void {
    //     cmd_buffer.endRenderpass(context);
    // }
};
