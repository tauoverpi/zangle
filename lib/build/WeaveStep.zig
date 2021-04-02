const std = @import("std");
const fs = std.fs;
const Step = std.build.Step;
const Builder = std.build.Builder;
const ArrayList = std.ArrayList;

const lib = @import("../lib.zig");
const Tree = lib.Tree;
const Weaver = lib.Tree.Weaver;

const WeaveStep = @This();

step: Step,
builder: *Builder,
source: ArrayList(File),
output_filename: []const u8,
weaver: Weaver,

pub const File = union(enum) {
    text: []const u8,
    path: []const u8,
};

pub fn init(builder: *Builder, weaver: Weaver, filename: []const u8) !*WeaveStep {
    const self = try builder.allocator.create(WeaveStep);
    self.* = WeaveStep{
        .builder = builder,
        .step = Step.init(.WriteFile, "TangleFileStep", builder.allocator, make),
        .source = ArrayList(File).init(builder.allocator),
        .output_filename = filename,
        .weaver = weaver,
    };
    return self;
}

pub fn addFile(self: *WeaveStep, path: []const u8) !void {
    const dupe = self.builder.dupe(path);
    try self.source.append(.{ .path = dupe });
}

pub fn addText(self: *WeaveStep, text: []const u8) !void {
    const dupe = self.builder.dupe(text);
    try self.source.append(.{ .text = dupe });
}

fn make(step: *Step) !void {
    const self = @fieldParentPtr(WeaveStep, "step", step);

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

    const filename = self.builder.pathFromRoot(self.output_filename);
    var file = try fs.cwd().createFile(filename, .{ .truncate = true });
    defer file.close();

    try tree.weave(self.weaver, file.writer());
}
