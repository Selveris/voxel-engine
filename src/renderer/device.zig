const std = @import("std");
const vk = @import("vulkan");

const ctx = @import("context.zig");

const logger = std.log.scoped(.device);
const device_requirement: PhysicalDeviceRequirement = .{
    .graphics = true,
    .present = true,
    .transfer = true,
    .extensions = &.{vk.extensions.khr_swapchain.name},
};

pub const DeviceError = error{
    NoSuitableDevice,
};

pub fn selectPhysicalDevice(allocator: std.mem.Allocator, context: ctx.VkContext) !DeviceCandidate {
    const pdevs = try context.vki.enumeratePhysicalDevicesAlloc(context.instance, allocator);
    defer allocator.free(pdevs);
    var candidates = std.ArrayList(DeviceCandidate).init(allocator);
    defer candidates.deinit();

    for (pdevs) |pdev| {
        const properties = context.vki.getPhysicalDeviceProperties(pdev);
        //        const features = context.vki.getPhysicalDeviceFeatures(pdev);
        //        const memory = context.vki.getPhysicalDeviceMemoryProperties(pdev);
        logger.debug("Vulkan: checking physical device {s}", .{properties.device_name});

        const queues_properties = try context.vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
        const queues_info = try constructQueuesInfo(allocator, pdev, queues_properties, context);
        const exts = try context.vki.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);

        const candidate: DeviceCandidate = .{
            .pdev = pdev,
            .props = properties,
            .exts = exts,
            .queues = queues_info,
        };
        if (deviceMeetRequirements(candidate)) {
            try candidates.append(candidate);
            logger.debug("Vulkan: device '{s}' meets requirements", .{properties.device_name});
        }
    }
    if (candidates.items.len == 0) {
        logger.err("Vulkan: no suitable physical device has been found", .{});
        return DeviceError.NoSuitableDevice;
    }

    return pickDeviceCandidate(candidates.items);
}

fn constructQueuesInfo(allocator: std.mem.Allocator, pdev: vk.PhysicalDevice, qprops: []vk.QueueFamilyProperties, context: ctx.VkContext) !QueueInfo {
    var queues_info = QueueInfo.init(allocator);
    errdefer queues_info.deinit();

    for (qprops, 0..) |props, i| {
        queues_info.total_queues_count += props.queue_count;
        if (props.queue_flags.graphics_bit) {
            try queues_info.graphics_family.append(@intCast(i));
        }
        if (props.queue_flags.compute_bit) {
            try queues_info.compute_family.append(@intCast(i));
        }
        if (props.queue_flags.transfer_bit) {
            if (!props.queue_flags.graphics_bit) {
                try queues_info.transfer_family.insert(0, @intCast(i));
            } else {
                try queues_info.transfer_family.append(@intCast(i));
            }
        }
        if (try context.vki.getPhysicalDeviceSurfaceSupportKHR(pdev, @intCast(i), context.surface) == vk.TRUE) {
            try queues_info.present_family.append(@intCast(i));
        }
    }
    logger.debug("  queues infos -- graphics: {any}, compute: {any}, present: {any}, transfer: {any}", .{
        queues_info.graphics_family.items,
        queues_info.compute_family.items,
        queues_info.present_family.items,
        queues_info.transfer_family.items,
    });
    return queues_info;
}

fn deviceMeetRequirements(candidate: DeviceCandidate) bool {
    for (device_requirement.extensions) |req_ext| {
        for (candidate.exts) |ext| {
            const len = std.mem.indexOfScalar(u8, &ext.extension_name, 0).?;
            const ext_name = ext.extension_name[0..len];
            if (std.mem.eql(u8, std.mem.span(req_ext), ext_name)) {
                break;
            }
        } else {
            return false;
        }
    }
    if (device_requirement.graphics and candidate.queues.graphics_family.items.len == 0) return false;
    if (device_requirement.compute and candidate.queues.compute_family.items.len == 0) return false;
    if (device_requirement.present and candidate.queues.present_family.items.len == 0) return false;
    if (device_requirement.transfer and candidate.queues.transfer_family.items.len == 0) return false;
    return true;
}

fn pickDeviceCandidate(candidates: []DeviceCandidate) DeviceCandidate {
    var max_count: usize = 0;
    var selected: usize = 0;

    for (candidates, 0..) |candidate, i| {
        if (candidate.queues.total_queues_count > max_count) {
            max_count = candidate.queues.total_queues_count;
            selected = i;
        }
    }
    return candidates[selected];
}

const PhysicalDeviceRequirement = struct {
    graphics: bool = false,
    present: bool = false,
    compute: bool = false,
    transfer: bool = false,

    extensions: []const [*:0]const u8,
};

pub const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    exts: []vk.ExtensionProperties,
    queues: QueueInfo,
};

pub const QueueInfo = struct {
    graphics_family: std.ArrayList(u32),
    present_family: std.ArrayList(u32),
    compute_family: std.ArrayList(u32),
    transfer_family: std.ArrayList(u32),
    total_queues_count: usize = 0,

    fn init(allocator: std.mem.Allocator) QueueInfo {
        return .{
            .graphics_family = std.ArrayList(u32).init(allocator),
            .present_family = std.ArrayList(u32).init(allocator),
            .compute_family = std.ArrayList(u32).init(allocator),
            .transfer_family = std.ArrayList(u32).init(allocator),
        };
    }
    fn deinit(self: *QueueInfo) void {
        self.graphics_family.deinit();
        self.present_family.deinit();
        self.compute_family.deinit();
        self.transfer_family.deinit();
    }
};
