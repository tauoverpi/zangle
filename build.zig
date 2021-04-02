const std = @import("std");
const Builder = std.build.Builder;
const RunStep = std.build.RunStep;
const lib = @import("lib/lib.zig");

const pkgs = struct {
    const zangle = std.build.Pkg{
        .name = "lib",
        .path = "lib/lib.zig",
    };
};

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const tangler = try lib.build.TangleFilesStep.init(b);
    try tangler.addFile("docs/zangle.md");

    const tangle_step = b.step("tangle", "Extract executable code from documentation");
    tangle_step.dependOn(&tangler.step);

    const weaver = try lib.build.WeaveStep.init(b, .github, "README.md");
    try weaver.addFile("docs/zangle.md");

    const weave_step = b.step("weave", "Pretty print documentation");
    weave_step.dependOn(&weaver.step);

    const doctest = try lib.build.DocTestStep.init(b);
    try doctest.addFile("docs/zangle.md");

    const doctest_step = b.step("doctest", "Extract executable code from documentation and run zig test");
    doctest_step.dependOn(&doctest.step);

    const fmt_step = b.addFmt(&.{"src"});
    fmt_step.step.dependOn(tangle_step);

    const exe = b.addExecutable("zangle", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.step.dependOn(&fmt_step.step);
    exe.addPackage(pkgs.zangle);
    exe.addLibPath("lib/lib.zig");
    exe.install();

    const pdf_step = b.step("pdf", "Render documentation to PDF");
    pdf_step.dependOn(&(try pandoc(b, &.{ "docs/zangle.md", "-o", "out/manual.pdf" })).step);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const main_test = b.addTest("src/main.zig");
    main_test.addPackage(pkgs.zangle);

    const test_step = b.step("test", "Run application unit tests");
    test_step.dependOn(tangle_step);
    test_step.dependOn(&main_test.step);

    const lib_test_step = b.step("test-lib", "Run library unit tests");
    lib_test_step.dependOn(doctest_step);
    lib_test_step.dependOn(&b.addTest("lib/lib.zig").step);
}

fn pandoc(b: *Builder, args: []const []const u8) !*RunStep {
    var list = std.ArrayList([]const u8).init(b.allocator);
    try list.appendSlice(&[_][]const u8{
        "pandoc",
        "--pdf-engine=xelatex",
        "--standalone",
        "--filter=pandoc-crossref",
        "--filter=pandoc-citeproc",
        "--syntax-definition=misc/syntax.xml",
        "--highlight-style=misc/syntax.theme",
        "--csl=misc/ieee.csl",
    });

    try list.appendSlice(args);

    const step = b.addSystemCommand(list.items);
    return step;
}
