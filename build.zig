const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });
    const dep = b.dependency("zangle", .{});
    const zangle = dep.artifact("zangle");
    zangle.target = target;
    zangle.optimize = optimize;

    b.installArtifact(zangle);
    const run_cmd = b.addRunArtifact(zangle);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
