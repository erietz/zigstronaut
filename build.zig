const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zigstronaut",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zigstronaut");
    run_step.dependOn(&run_cmd.step);

    // Cross-compilation targets for release builds
    const cross_step = b.step("cross", "Build for all supported platforms");

    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };

    for (targets) |t| {
        const cross_exe = b.addExecutable(.{
            .name = "zigstronaut",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(t),
                .optimize = .ReleaseSafe,
                .link_libc = true,
            }),
        });
        const dest = crossDirName(t);
        const cross_install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = dest } },
        });
        cross_step.dependOn(&cross_install.step);
    }
}

fn crossDirName(t: std.Target.Query) []const u8 {
    if (t.os_tag.? == .linux and t.cpu_arch.? == .x86_64) return "linux-x86_64";
    if (t.os_tag.? == .linux and t.cpu_arch.? == .aarch64) return "linux-aarch64";
    if (t.os_tag.? == .macos and t.cpu_arch.? == .x86_64) return "macos-x86_64";
    if (t.os_tag.? == .macos and t.cpu_arch.? == .aarch64) return "macos-aarch64";
    if (t.os_tag.? == .windows and t.cpu_arch.? == .x86_64) return "windows-x86_64";
    if (t.os_tag.? == .windows and t.cpu_arch.? == .aarch64) return "windows-aarch64";
    return "unknown";
}
