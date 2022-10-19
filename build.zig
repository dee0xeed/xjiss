const std = @import("std");

pub fn build(b: *std.build.Builder) void {

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("xjiss", "src/main.zig");
    exe.linkLibC();
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("asound");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();
}
