const std = @import("std");
const TangleStep = @import("lib/lib.zig").TangleStep;

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

    const tangle = try TangleStep.create(b);
    try tangle.add("README.md");

    const tangle_step = b.step("tangle", "Tangle zangle main");
    tangle_step.dependOn(&tangle.step);

    const exe = b.addExecutableSource("zangle", try tangle.getFileSource("main.zig"));

    exe.addPackagePath("zangle", "lib/lib.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Test the app");
    const test_cmd = b.addTest("lib/lib.zig");
    const test_main_cmd = b.addTestSource(try tangle.getFileSource("main.zig"));
    test_step.dependOn(&test_cmd.step);
    test_step.dependOn(&test_main_cmd.step);

    const web = try TangleStep.create(b);
    web.output_dir = ".";
    try web.add("docs/index.md");

    const web_step = b.step("web", "Generate project page");
    web_step.dependOn(&web.step);
    _ = try web.getFileSource("index.html");
}
