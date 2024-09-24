const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl2");
const vk = @import("vulkan");

const vk_api = @import("vulkan_api.zig");
const window = @import("window.zig");
const dev = @import("device.zig");

const logger = std.log.scoped(.context);

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
    debug_messenger: vk.DebugUtilsMessengerEXT,

    device_info: dev.DeviceCandidate,
    dev: vk.Device,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    compute_queue: vk.Queue,
    transfer_queue: vk.Queue,

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
        if (builtin.mode == .Debug) {
            self.init_debugger();
        }
        self.vki = try vk_api.InstanceDispatch.load(self.instance, self.vkb.dispatch.vkGetInstanceProcAddr);
        errdefer self.vki.destroyInstance(self.instance, self.vk_allocator);
        logger.info("Vulkan: successfully initialized instance for app '{s}'", .{app_name});

        self.surface = try display.create_surface(self.instance);
        errdefer self.vki.destroySurfaceKHR(self.instance, self.surface, self.vk_allocator);

        self.device_info = try dev.selectPhysicalDevice(tmp_allocator, self);
        logger.info("Vulkan: selected physical device '{s}'", .{self.device_info.props.device_name});
        const queue_create_info: []const vk.DeviceQueueCreateInfo = try dev.getQueueCreateInfo(tmp_allocator, self.device_info.queues);
        self.dev = try self.vki.createDevice(self.device_info.pdev, &.{
            .flags = .{},
            .queue_create_info_count = @intCast(queue_create_info.len),
            .p_queue_create_infos = @ptrCast(queue_create_info),
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = undefined,
            .enabled_extension_count = @as(u32, @intCast(self.device_info.exts.items.len)),
            .pp_enabled_extension_names = @as([*]const [*:0]const u8, @ptrCast(self.device_info.exts.items)),
            .p_enabled_features = null,
        }, self.vk_allocator);
        self.vkd = try vk_api.DeviceDispatch.load(self.dev, self.vki.dispatch.vkGetDeviceProcAddr);
        errdefer self.vkd.destroyDevice(self.dev, null);
        logger.info("Vulkan: successfully initialized logical device", .{});

        const queue_count = try tmp_allocator.alloc(u32, self.device_info.queues.family_count);
        @memset(queue_count, 0);
        if (self.device_info.queues.graphics_family.items.len > 0) {
            const family_index = self.device_info.queues.graphics_family.items[0];
            self.graphics_queue = self.vkd.getDeviceQueue(self.dev, family_index, queue_count[family_index]);
            queue_count[family_index] += 1;
        }
        if (self.device_info.queues.compute_family.items.len > 0) {
            const family_index = self.device_info.queues.compute_family.items[0];
            self.compute_queue = self.vkd.getDeviceQueue(self.dev, family_index, queue_count[family_index]);
            queue_count[family_index] += 1;
        }
        if (self.device_info.queues.present_family.items.len > 0) {
            const family_index = self.device_info.queues.present_family.items[0];
            self.present_queue = self.vkd.getDeviceQueue(self.dev, family_index, queue_count[family_index]);
            queue_count[family_index] += 1;
        }
        if (self.device_info.queues.transfer_family.items.len > 0) {
            const family_index = self.device_info.queues.transfer_family.items[0];
            self.transfer_queue = self.vkd.getDeviceQueue(self.dev, family_index, queue_count[family_index]);
            queue_count[family_index] += 1;
        }
        logger.info("Vulkan: queues handles successfully obtained", .{});

        return self;
    }

    pub fn deinit(self: VkContext) void {
        self.vkd.destroyDevice(self.dev, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        // TODO: deinit debugger messenger
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
        if (builtin.mode == .Debug) {
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
        if (builtin.mode == .Debug) {
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

    fn init_debugger(self: *VkContext) void {
        const log_severity: vk.DebugUtilsMessageSeverityFlagsEXT = .{
            .error_bit_ext = true,
            .warning_bit_ext = true,
        };
        const log_type: vk.DebugUtilsMessageTypeFlagsEXT = .{
            .general_bit_ext = true,
            .performance_bit_ext = true,
            .validation_bit_ext = true,
        };
        const debug_info = vk.DebugUtilsMessengerCreateInfoEXT{
            .message_severity = log_severity,
            .message_type = log_type,
            .pfn_user_callback = vk_debug_callback,
        };
        const pfn: ?vk.PfnCreateDebugUtilsMessengerEXT = @ptrCast(self.vkb.getInstanceProcAddr(self.instance, "vkCreateDebugUtilsMessengerEXT"));
        if (pfn == null) {
            logger.err("Vulkan: did not found PFN for CreateDebugUtilsMessengerEXT", .{});
        }
        const res = pfn.?(self.instance, &debug_info, self.vk_allocator, &self.debug_messenger);
        switch (res) {
            vk.Result.success => {
                logger.info("Vulkan: successfully created debugger", .{});
            },
            else => |err| {
                logger.warn("Vulkan: failed to initialize debbuger: {any}", .{err});
            },
        }
    }
};

fn vk_debug_callback(severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, user_data: ?*anyopaque) callconv(.C) vk.Bool32 {
    _ = user_data;
    if (callback_data == null) return vk.FALSE;

    var log_context: []const u8 = undefined;
    if (types.general_bit_ext) {
        log_context = "vulkan-general";
    } else if (types.validation_bit_ext) {
        log_context = "vulkan-validation";
    } else if (types.performance_bit_ext) {
        log_context = "vulkan-performance";
    } else {
        log_context = "vulkan-unknown-source";
    }
    const format = "{s}: {s}";
    const args = .{ log_context, callback_data.?.p_message.? };
    if (severity.error_bit_ext) {
        logger.err(format, args);
    } else if (severity.warning_bit_ext) {
        logger.warn(format, args);
    } else if (severity.info_bit_ext) {
        logger.info(format, args);
    } else if (severity.verbose_bit_ext) {
        logger.debug(format, args);
    }

    return vk.FALSE;
}
