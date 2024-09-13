const std = @import("std");
const sdl = @import("sdl_wrappers");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_root_path = "src/lib.zig";
    const exe_root_path = "src/main.zig";

    /////////////////////////////////////
    // Link dependencies
    /////////////////////////////////////

    // Vulkan bindings
    const vk_registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    const vk_gen = b.dependency("vulkan_wrappers", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addArg(vk_registry.getPath(b));
    const vulkan_zig = b.addModule("vulkan_wrappers", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });

    // SDL2 bindings
    const sdl_sdk = sdl.init(b, null, null);

    /////////////////////////////////////
    // Define lib and exe
    /////////////////////////////////////

    // const lib = b.addStaticLibrary(.{
    //     .name = "scop",
    //     // In this case the main source file is merely a path, however, in more
    //     // complicated build scripts, this could be a generated file.
    //     .root_source_file = b.path(lib_root_path),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "voxel-engine",
        .root_source_file = b.path(exe_root_path),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    exe.root_module.addImport("vulkan", vulkan_zig);
    exe.root_module.addImport("sdl2", sdl_sdk.getWrapperModuleVulkan(vulkan_zig));
    sdl_sdk.link(exe, .dynamic, sdl.Library.SDL2);

    /////////////////////////////////////
    // Define commandes
    /////////////////////////////////////

    //RUN
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    //TEST
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path(lib_root_path),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path(exe_root_path),
        .target = target,
        .optimize = optimize,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
