const std = @import("std");
const fs = std.fs;
const Step = std.build.Step;
const Builder = std.build.Builder;
const ArrayList = std.ArrayList;

const lib = @import("../lib.zig");
const Tree = lib.Tree;

const DocTestStep = @This();

step: Step,
builder: *Builder,
output_dir: []const u8,
source: ArrayList(File),

pub const File = union(enum) {
    text: []const u8,
    path: []const u8,
};

pub fn init(builder: *Builder) !*DocTestStep {
    const self = try builder.allocator.create(DocTestStep);
    self.* = DocTestStep{
        .builder = builder,
        .step = Step.init(.WriteFile, "TangleFileStep", builder.allocator, make),
        .source = ArrayList(File).init(builder.allocator),
        .output_dir = undefined,
    };
    return self;
}

pub fn addFile(self: *DocTestStep, path: []const u8) !void {
    const dupe = self.builder.dupe(path);
    try self.source.append(.{ .path = dupe });
}

pub fn addText(self: *DocTestStep, text: []const u8) !void {
    const dupe = self.builder.dupe(text);
    try self.source.append(.{ .text = dupe });
}

fn make(step: *Step) !void {
    const self = @fieldParentPtr(DocTestStep, "step", step);

    var stack = ArrayList(Tree.RenderNode).init(self.builder.allocator);
    defer stack.deinit();

    var source = ArrayList(u8).init(self.builder.allocator);
    for (self.source.items) |item| switch (item) {
        .text => |text| try source.appendSlice(text),
        .path => |path| {
            var fifo = std.fifo.LinearFifo(u8, .{ .Static = std.mem.page_size }).init();
            var file = try fs.cwd().openFile(path, .{});
            defer file.close();
            try fifo.pump(file.reader(), source.writer());
        },
    };

    var tree = try Tree.parse(self.builder.allocator, source.items);
    defer tree.deinit(self.builder.allocator);

    var digest: [48]u8 = undefined;
    const hash = std.crypto.hash.blake2.Blake2b384.hash(source.items, &digest, .{});
    var hash_basename: [64]u8 = undefined;
    _ = fs.base64_encoder.encode(&hash_basename, &digest);

    const output_dir = try fs.path.join(self.builder.allocator, &.{
        self.builder.cache_root,
        "o",
        &hash_basename,
    });

    try self.builder.makePath(output_dir);

    const tokens = tree.tokens.items(.start);

    for (tree.doctests) |root| {
        var tmp: [64]u8 = undefined;
        const filename = try fs.path.join(self.builder.allocator, &.{
            output_dir,
            try std.fmt.bufPrint(&tmp, "test-{}.zig", .{tokens[root.index]}),
        });

        {
            var file = try fs.cwd().createFile(filename, .{ .truncate = true });
            defer file.close();

            try tree.tangle(&stack, .{ .index = root.index }, file.writer());
        }

        const result = try std.ChildProcess.exec(.{
            .argv = &.{ "zig", "test", filename },
            .allocator = self.builder.allocator,
        });

        errdefer {
            std.debug.print("{s}", .{result.stderr});
        }

        defer self.builder.allocator.free(result.stderr);
        defer self.builder.allocator.free(result.stdout);

        switch (result.term) {
            .Exited => |code| if (code != 0) {
                std.debug.print("failed test with exit code {}", .{code});
                return error.FailedTest;
            },
            else => return error.FailedTest,
        }
    }
}
