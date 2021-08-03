const std = @import("std");
const build = std.build;
const fs = std.fs;
const Step = std.build.Step;
const Builder = std.build.Builder;
const TangleStep = @This();
const Linker = @import("Linker.zig");
const Compiler = @import("Compiler.zig");
const Interpreter = @import("Interpreter.zig");

step: Step,
builder: *Builder,
files: FileList,
sources: SourceList,
output_dir: ?[]const u8,

const FileList = std.TailQueue(File);

pub const File = struct {
    path: []const u8,
};

const SourceList = std.TailQueue(Source);

pub const Source = struct {
    source: build.GeneratedFile,
    path: []const u8,
};

pub fn create(builder: *Builder) !*TangleStep {
    const self = try builder.allocator.create(TangleStep);
    self.* = .{
        .builder = builder,
        .step = Step.init(.custom, "tangle", builder.allocator, make),
        .files = .{},
        .sources = .{},
        .output_dir = null,
    };

    return self;
}

pub fn add(self: *TangleStep, path: []const u8) !void {
    const node = try self.builder.allocator.create(FileList.Node);
    node.* = .{
        .data = .{
            .path = self.builder.dupe(path),
        },
    };

    self.files.append(node);
}

pub fn getFileSource(self: *TangleStep, path: []const u8) !build.FileSource {
    var it = self.sources.first;
    while (it) |node| : (it = node.next) {
        if (std.mem.eql(u8, node.data.path, path))
            return build.FileSource{ .generated = &node.data.source };
    }

    const node = try self.builder.allocator.create(SourceList.Node);
    node.* = .{
        .data = .{
            .source = .{ .step = &self.step },
            .path = self.builder.dupe(path),
        },
    };

    self.sources.append(node);

    return build.FileSource{ .generated = &node.data.source };
}

fn make(step: *Step) !void {
    const self = @fieldParentPtr(TangleStep, "step", step);

    var vm: Interpreter = .{ .linker = .{} };
    defer vm.linker.deinit(self.builder.allocator);
    defer vm.deinit(self.builder.allocator);

    var hash = std.crypto.hash.blake2.Blake2b384.init(.{});
    hash.update("lsDJht802Ndc901");

    {
        var it = self.files.first;
        while (it) |node| : (it = node.next) {
            const path = try fs.path.join(self.builder.allocator, &.{
                self.builder.build_root,
                node.data.path,
            });
            defer self.builder.allocator.free(path);

            const bytes = try fs.cwd().readFileAlloc(self.builder.allocator, path, 0x7fff_ffff);
            errdefer self.builder.allocator.free(bytes);

            hash.update(bytes);

            try vm.linker.objects.append(
                self.builder.allocator,
                try Compiler.parseAndCompile(self.builder.allocator, bytes),
            );
        }
    }

    defer for (vm.linker.objects.items) |obj| self.builder.allocator.free(obj.text);

    try vm.linker.link(self.builder.allocator);

    var digest: [48]u8 = undefined;
    hash.final(&digest);

    var basename: [64]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&basename, &digest);

    if (self.output_dir == null) self.output_dir = try fs.path.join(self.builder.allocator, &.{
        self.builder.cache_root,
        "o",
        &basename,
    });

    try std.fs.cwd().makePath(self.output_dir.?);

    var dir = try fs.cwd().openDir(self.output_dir.?, .{});
    defer dir.close();

    var it = self.sources.first;
    while (it) |node| : (it = node.next) {
        if (fs.path.dirname(node.data.path)) |dirname| try dir.makePath(dirname);
        var file = try dir.createFile(node.data.path, .{ .truncate = true });
        defer file.close();

        var buff = std.io.bufferedWriter(file.writer());

        try vm.call(self.builder.allocator, node.data.path, buff.writer());

        try buff.flush();

        node.data.source.path = try fs.path.join(
            self.builder.allocator,
            &.{ self.output_dir.?, node.data.path },
        );
    }
}
