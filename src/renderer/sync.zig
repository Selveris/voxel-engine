const std = @import("std");
const vk = @import("vulkan");

const ctx = @import("context.zig");

const logger = std.log.scoped(.sync);

pub const SyncError = error{
    Timeout,
    Unknown,
};

pub const Fence = struct {
    handle: vk.Fence,
    signaled: bool,

    pub fn init(context: ctx.VkContext, signaled: bool) !Fence {
        const create_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = signaled },
        };
        const handle = try context.vkd.createFence(context.dev, &create_info, context.vk_allocator);
        return Fence{
            .handle = handle,
            .signaled = signaled,
        };
    }
    pub fn deinit(self: *Fence, context: ctx.VkContext) void {
        context.vkd.destroyFence(context.dev, self, context.vk_allocator);
    }

    pub fn wait(self: *Fence, context: ctx.VkContext, timeout: u64) !void {
        if (self.signaled) return;

        const result = try context.vkd.waitForFences(context.dev, 1, self, vk.TRUE, timeout);
        switch (result) {
            .success => return,
            .timeout => {
                logger.warn("Vulkan: fence wait timed out");
                return SyncError.Timeout;
            },
            else => return SyncError.Unknown,
        }
    }
    pub fn reset(self: *Fence, context: ctx.VkContext) void {
        try context.vkd.resetFences(context.dev, 1, self);
    }
};
