const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows },
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });

    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary("user32", .{});
    exe_mod.linkSystemLibrary("gdi32", .{});
    exe_mod.linkSystemLibrary("winmm", .{});
    exe_mod.linkSystemLibrary("kernel32", .{});
    exe_mod.linkSystemLibrary("comdlg32", .{});
    exe_mod.linkSystemLibrary("shell32", .{});
    exe_mod.linkSystemLibrary("ole32", .{});
    exe_mod.linkSystemLibrary("dwmapi", .{});

    const exe = b.addExecutable(.{
        .name = "ZigBoy",
        .root_module = exe_mod,
    });
    exe.subsystem = .Windows;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the emulator");
    run_step.dependOn(&run_cmd.step);
}
