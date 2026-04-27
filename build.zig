const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows, .abi = .gnu },
    });
    const user_optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size");
    const optimize: std.builtin.OptimizeMode = user_optimize orelse .ReleaseFast;

    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .linkage = std.builtin.LinkMode.static,
    });
    const raylib_artifact = raylib_dep.artifact("raylib");
    const raylib_mod = raylib_dep.module("raylib");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.link_libc = true;
    exe_mod.addImport("raylib", raylib_mod);
    exe_mod.linkLibrary(raylib_artifact);
    if (target.result.os.tag == .windows) {
        exe_mod.linkSystemLibrary("comdlg32", .{});
        exe_mod.linkSystemLibrary("shell32", .{});
        exe_mod.linkSystemLibrary("ole32", .{});
        exe_mod.linkSystemLibrary("user32", .{});
        exe_mod.linkSystemLibrary("kernel32", .{});
        exe_mod.linkSystemLibrary("dwmapi", .{});
    }

    const exe = b.addExecutable(.{
        .name = "ZigBoy",
        .root_module = exe_mod,
    });
    exe.subsystem = .Windows;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run ZigBoy");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);
}
