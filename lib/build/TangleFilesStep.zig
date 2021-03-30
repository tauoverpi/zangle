const std = @import("std");
const fs = std.fs;
const Step = std.build.Step;
const Builder = std.build.Builder;
const ArrayList = std.ArrayList;

const lib = @import("../lib.zig");
const Tree = lib.Tree;

const TangleFilesStep = @This();

step: Step,
builder: *Builder,
output_dir: []const u8,
source: ArrayList(File),

pub const File = union(enum) {
    text: []const u8,
    path: []const u8,
};

pub fn init(builder: *Builder) !*TangleFilesStep {
    const self = try builder.allocator.create(TangleFilesStep);
    self.* = TangleFilesStep{
        .builder = builder,
        .step = Step.init(.WriteFile, "TangleFileStep", builder.allocator, make),
        .source = ArrayList(File).init(builder.allocator),
        .output_dir = undefined,
    };
    return self;
}

pub fn addFile(self: *TangleFilesStep, path: []const u8) !void {
    const dupe = self.builder.dupe(path);
    try self.source.append(.{ .path = dupe });
}

pub fn addText(self: *TangleFilesStep, text: []const u8) !void {
    const dupe = self.builder.dupe(text);
    try self.source.append(.{ .text = dupe });
}

fn make(step: *Step) !void {
    const self = @fieldParentPtr(TangleFilesStep, "step", step);

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

    for (tree.roots) |root| {
        const filename = self.builder.pathFromRoot(tree.filename(root));
        if (fs.path.dirname(filename)) |dir| try self.builder.makePath(dir);
        var file = try fs.cwd().openFile(filename, .{ .write = true });
        defer file.close();
        try tree.render(&stack, root, file.writer());
    }
}
