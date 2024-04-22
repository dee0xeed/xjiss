const std = @import("std");

pub fn build(b: *std.Build) void {

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "xjiss",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
//        .strip = true,
        .link_libc = true,
    });

    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("asound");

    b.installArtifact(exe);
}
