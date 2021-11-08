const std = @import("std");
const lib = @import("lib/lib.zig");
const TangleStep = lib.TangleStep;

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    b.setPreferredReleaseMode(.ReleaseSafe);
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zangle", "src/main.zig");

    const fmt_check_step = &b.addSystemCommand(&.{ "zig", "fmt", "--check", "--ast-check", "src", "lib" }).step;

    exe.addPackagePath("lib", "lib/lib.zig");
    exe.step.dependOn(fmt_check_step);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const wa = b.addSharedLibrary("zangle", "lib/wasm.zig", .unversioned);
    wa.step.dependOn(fmt_check_step);
    wa.setTarget(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    wa.setBuildMode(mode);
    wa.install();

    const tangle = TangleStep.create(b);
    tangle.addFile("README.md");
    const t_exe = b.addExecutableSource("zangle", tangle.getFileSource("src/main.zig"));
    t_exe.addPackage(.{
        .name = "lib",
        .path = tangle.getFileSource("lib/lib.zig"),
    });

    const tangle_test_step = b.step("test-step", "Test compiling zangle using the build step");
    tangle_test_step.dependOn(&tangle.step);
    tangle_test_step.dependOn(&b.addInstallArtifact(t_exe).step);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_cmd = b.addTest("lib/lib.zig");
    const test_main_cmd = b.addTest("src/main.zig");

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(fmt_check_step);
    test_step.dependOn(&test_cmd.step);
    test_step.dependOn(&test_main_cmd.step);
}
