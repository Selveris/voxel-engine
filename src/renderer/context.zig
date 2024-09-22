const std = @import("std");
const sdl = @import("sdl2");
const vk = @import("vulkan");
const vk_api = @import("vulkan_api.zig");
const window = @import("window.zig");

const logger = std.log.scoped(.context);

const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};
const optional_device_extensions = [_][*:0]const u8{};
const optional_instance_extensions = [_][*:0]const u8{
    vk.extensions.khr_get_physical_device_properties_2.name,
};
const optional_instance_layers = [_][*:0]const u8{
    "VK_LAYER_NV_optimus",
};

pub const VkContextError = error{
    OutOfMemory,
    Instance,
    MissingLayer,
};

pub const VkContext = struct {
    vkb: vk_api.BaseDispatch,
    vki: vk_api.InstanceDispatch,
    vkd: vk_api.DeviceDispatch,
    vk_allocator: ?*const vk.AllocationCallbacks,

    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    dev: vk.Device,
    graphics_queue: Queue,
    present_queue: Queue,
    compute_queue: Queue,

    pub fn init(allocator: ?*const vk.AllocationCallbacks, app_name: [*:0]const u8, display: window.WindowDisplay) !VkContext {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const tmp_allocator = arena.allocator();
        var self: VkContext = undefined;
        self.vk_allocator = allocator;

        self.vkb = try vk_api.BaseDispatch.load(try sdl.vulkan.getVkGetInstanceProcAddr());
        self.instance = self.init_instance(tmp_allocator, app_name, display) catch |err| {
            logger.err("Vulkan: failed to initialize instance for app '{s}': {}", .{ app_name, err });
            return VkContextError.Instance;
        };
        logger.info("Vulkan: successfully initialized instance for app '{s}'", .{app_name});

        self.vki = try vk_api.InstanceDispatch.load(self.instance, self.vkb.dispatch.vkGetInstanceProcAddr);
        errdefer self.vki.destroyInstance(self.instance, self.vk_allocator);

        self.surface = try display.create_surface(self.instance);
        errdefer self.vki.destroySurfaceKHR(self.instance, self.surface, self.vk_allocator);

        const candidate = try pickPhysicalDevice(self.vki, self.instance, tmp_allocator, self.surface);
        self.pdev = candidate.pdev;
        self.props = candidate.props;
        self.dev = try initializeCandidate(tmp_allocator, self.vki, candidate);
        self.vkd = try vk_api.DeviceDispatch.load(self.dev, self.vki.dispatch.vkGetDeviceProcAddr);
        errdefer self.vkd.destroyDevice(self.dev, null);

        self.graphics_queue = Queue.init(self.vkd, self.dev, candidate.queues.graphics_family);
        self.present_queue = Queue.init(self.vkd, self.dev, candidate.queues.present_family);
        if (candidate.queues.compute_family != null) {
            self.compute_queue = Queue.init(self.vkd, self.dev, candidate.queues.compute_family.?);
        }

        self.mem_props = self.vki.getPhysicalDeviceMemoryProperties(self.pdev);

        return self;
    }

    pub fn deinit(self: VkContext) void {
        self.vkd.destroyDevice(self.dev, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vki.destroyInstance(self.instance, null);
    }

    pub fn deviceName(self: VkContext) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.props.device_name, 0).?;
        return self.props.device_name[0..len];
    }

    pub fn findMemoryTypeIndex(self: VkContext, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
            if (memory_type_bits & (@as(u32, 1) << @as(u5, @truncate(i))) != 0 and mem_type.property_flags.contains(flags)) {
                return @as(u32, @truncate(i));
            }
        }

        return error.NoSuitableMemoryType;
    }

    pub fn allocate(self: VkContext, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
        return try self.vkd.allocateMemory(self.dev, &.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
        }, null);
    }

    fn init_instance(self: *VkContext, tmp_allocator: std.mem.Allocator, app_name: [*:0]const u8, display: window.WindowDisplay) !vk.Instance {
        // EXTENSIONS

        const app_info = vk.ApplicationInfo{
            .api_version = vk.makeApiVersion(0, 1, 3, 0),
            .p_application_name = app_name,
            .application_version = vk.makeApiVersion(0, 0, 1, 0),
            .p_engine_name = "No Engine",
            .engine_version = vk.makeApiVersion(0, 0, 1, 0),
        };
        var instance_info = vk.InstanceCreateInfo{
            .p_application_info = &app_info,
            .enabled_extension_count = 0,
            .pp_enabled_extension_names = null,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
        };
        try self.init_extensions(tmp_allocator, &instance_info, display);
        try self.init_layers(tmp_allocator, &instance_info);

        logger.debug("Vulkan: enabled extensions:", .{});
        for (0..instance_info.enabled_extension_count) |i| {
            logger.debug("\t{s}", .{instance_info.pp_enabled_extension_names.?[i]});
        }
        logger.debug("Vulkan: enabled layers:", .{});
        for (0..instance_info.enabled_layer_count) |i| {
            logger.debug("\t{s}", .{instance_info.pp_enabled_layer_names.?[i]});
        }

        return self.vkb.createInstance(&instance_info, self.vk_allocator);
    }

    fn init_extensions(self: *VkContext, tmp_allocator: std.mem.Allocator, instance_info: *vk.InstanceCreateInfo, display: window.WindowDisplay) !void {
        const display_exts = try display.get_extensions(tmp_allocator);
        var exts = try std.ArrayList([*:0]const u8).initCapacity(tmp_allocator, display_exts.len);
        exts.appendSliceAssumeCapacity(display_exts);
        const propsv = try self.vkb.enumerateInstanceExtensionPropertiesAlloc(null, tmp_allocator);
        for (optional_instance_extensions) |ext_name| {
            for (propsv) |prop| {
                const len = std.mem.indexOfScalar(u8, &prop.extension_name, 0).?;
                const prop_ext_name = prop.extension_name[0..len];
                if (std.mem.eql(u8, prop_ext_name, std.mem.span(ext_name))) {
                    try exts.append(@ptrCast(ext_name));
                    break;
                }
            }
        }
        if (@import("builtin").mode == .Debug) {
            try exts.append(vk.extensions.ext_debug_utils.name);
        }

        if (exts.items.len > 0) {
            instance_info.enabled_extension_count = @intCast(exts.items.len);
            instance_info.pp_enabled_extension_names = @ptrCast(exts.items);
        }
    }

    fn init_layers(self: *VkContext, tmp_allocator: std.mem.Allocator, instance_info: *vk.InstanceCreateInfo) !void {
        var layers = try std.ArrayList([*:0]const u8).initCapacity(tmp_allocator, optional_instance_layers.len);
        layers.appendSliceAssumeCapacity(&optional_instance_layers);
        const layer_props = try self.vkb.enumerateInstanceLayerPropertiesAlloc(tmp_allocator);
        if (@import("builtin").mode == .Debug) {
            try layers.append("VK_LAYER_KHRONOS_validation");
        }
        var count = layers.items.len;
        while (count > 0) {
            count -= 1;
            var layer_name = layers.items[count];
            const len_name = std.mem.indexOfSentinel(u8, 0, layer_name);
            var layer_found: bool = false;
            for (layer_props) |prop| {
                const len_prop = std.mem.indexOfScalar(u8, &prop.layer_name, 0).?;
                if (std.mem.eql(u8, layer_name[0..len_name], prop.layer_name[0..len_prop])) {
                    layer_found = true;
                }
            }
            if (!layer_found) {
                logger.warn("Vulkan: validation layer '{s}' was not found", .{layer_name});
                _ = layers.swapRemove(count);
            }
        }
        if (layers.items.len > 0) {
            instance_info.enabled_layer_count = @intCast(layers.items.len);
            instance_info.pp_enabled_layer_names = @ptrCast(layers.items);
        }
    }
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(vkd: vk_api.DeviceDispatch, dev: vk.Device, family: u32) Queue {
        return .{
            .handle = vkd.getDeviceQueue(dev, family, 0),
            .family = family,
        };
    }
};

fn initializeCandidate(allocator: std.mem.Allocator, vki: vk_api.InstanceDispatch, candidate: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.compute_family.?,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1 // nvidia
    else
        2; // amd

    var device_extensions = try std.ArrayList([*:0]const u8).initCapacity(allocator, required_device_extensions.len);
    defer device_extensions.deinit();

    try device_extensions.appendSlice(required_device_extensions[0..required_device_extensions.len]);

    var count: u32 = undefined;
    _ = try vki.enumerateDeviceExtensionProperties(candidate.pdev, null, &count, null);

    const propsv = try allocator.alloc(vk.ExtensionProperties, count);
    defer allocator.free(propsv);

    _ = try vki.enumerateDeviceExtensionProperties(candidate.pdev, null, &count, propsv.ptr);

    for (optional_device_extensions) |extension_name| {
        for (propsv) |prop| {
            if (std.mem.eql(u8, prop.extension_name[0..prop.extension_name.len], std.mem.span(extension_name))) {
                try device_extensions.append(extension_name);
                break;
            }
        }
    }

    return try vki.createDevice(candidate.pdev, &.{
        .flags = .{},
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @as(u32, @intCast(device_extensions.items.len)),
        .pp_enabled_extension_names = @as([*]const [*:0]const u8, @ptrCast(device_extensions.items)),
        .p_enabled_features = null,
    }, null);
}

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
    compute_family: ?u32,
};

fn pickPhysicalDevice(
    vki: vk_api.InstanceDispatch,
    instance: vk.Instance,
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    const pdevs = try vki.enumeratePhysicalDevicesAlloc(instance, allocator);
    defer allocator.free(pdevs);

    for (pdevs) |pdev| {
        if (try checkSuitable(vki, pdev, allocator, surface)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(
    vki: vk_api.InstanceDispatch,
    pdev: vk.PhysicalDevice,
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
) !?DeviceCandidate {
    const props = vki.getPhysicalDeviceProperties(pdev);

    if (!try checkExtensionSupport(vki, pdev, allocator)) {
        return null;
    }

    if (!try checkSurfaceSupport(vki, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(vki, pdev, allocator, surface)) |allocation| {
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

fn allocateQueues(vki: vk_api.InstanceDispatch, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    var family_count: u32 = undefined;
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, null);

    const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, families.ptr);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;
    var compute_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family = @as(u32, @intCast(i));
        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try vki.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == vk.TRUE) {
            present_family = family;
        }

        if (compute_family == null and properties.queue_flags.compute_bit) {
            compute_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
            .compute_family = compute_family,
        };
    }

    return null;
}

fn checkSurfaceSupport(vki: vk_api.InstanceDispatch, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(
    vki: vk_api.InstanceDispatch,
    pdev: vk.PhysicalDevice,
    allocator: std.mem.Allocator,
) !bool {
    var count: u32 = undefined;
    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, null);

    const propsv = try allocator.alloc(vk.ExtensionProperties, count);
    defer allocator.free(propsv);

    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, propsv.ptr);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            const len = std.mem.indexOfScalar(u8, &props.extension_name, 0).?;
            const prop_ext_name = props.extension_name[0..len];
            if (std.mem.eql(u8, std.mem.span(ext), prop_ext_name)) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}
