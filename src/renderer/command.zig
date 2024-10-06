const vk = @import("vulkan");
const ctx = @import("context.zig");

pub const CommandBufferState = enum {
    initial,
    in_renderpass,
    recording,
    executable,
    submitted,
    invalid,
};

pub const CommandBuffer = struct {
    handle: vk.CommandBuffer,
    state: CommandBufferState,

    pub fn init(context: ctx.VkContext, cmd_pool: vk.CommandPool, level: vk.CommandBufferLevel) !CommandBuffer {
        const allocate_info: vk.CommandBufferAllocateInfo = .{
            .command_pool = cmd_pool,
            .level = level,
            .command_buffer_count = 1,
        };
        var handle: vk.CommandBuffer = .null_handle;
        try context.vkd.allocateCommandBuffers(context.dev, &allocate_info, @ptrCast(&handle));
        return CommandBuffer{
            .handle = handle,
            .state = CommandBufferState.initial,
        };
    }
    pub fn deinit(self: *CommandBuffer, context: *ctx.VkContext, cmd_pool: vk.CommandPool) void {
        context.vkd.freeCommandBuffers(context.dev, cmd_pool, 1, @ptrCast(&self.handle));
        self.handle = .null_handle;
    }
    pub fn begin(self: *CommandBuffer, context: ctx.VkContext, flags: vk.CommandBufferUsageFlags) !void {
        const begin_info: vk.CommandBufferBeginInfo = .{ .flags = flags };
        try context.vkd.beginCommandBuffer(self.handle, &begin_info);
        self.state = .recording;
    }
    pub fn end(self: *CommandBuffer, context: ctx.VkContext) !void {
        try context.vkd.endCommandBuffer(self.handle);
        self.state = .executable;
    }
    pub fn beginRenderpass(self: *CommandBuffer, context: ctx.VkContext, renderpass_info: *const vk.RenderPassBeginInfo) void {
        context.vkd.cmdBeginRenderPass(self, renderpass_info, .@"inline");
        self.state = .in_renderpass;
    }
    pub fn endRenderpass(self: *CommandBuffer, context: ctx.VkContext) void {
        context.vkd.cmdEndRenderPass(self);
        self.state = .recording;
    }
    pub fn submit(self: *CommandBuffer) void {
        self.state = .submitted;
    }
    pub fn reset(self: *CommandBuffer, context: ctx.VkContext, release_resources: bool) void {
        try context.vkd.resetCommandBuffer(self.handle, .{ .release_resources_bit = release_resources });
        self.state = .initial;
    }
};

pub fn createGraphicsPool(context: ctx.VkContext, graphics_family_index: u32) !vk.CommandPool {
    const create_info: vk.CommandPoolCreateInfo = .{
        .queue_family_index = graphics_family_index,
        .flags = .{ .reset_command_buffer_bit = true },
    };
    return try context.vkd.createCommandPool(context.dev, &create_info, context.vk_allocator);
}
