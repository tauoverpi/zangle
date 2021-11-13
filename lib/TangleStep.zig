const std = @import("std");
const lib = @import("lib.zig");
const fs = std.fs;
const mem = std.mem;
const io = std.io;

const TangleStep = @This();
const Allocator = std.mem.Allocator;
const Builder = std.build.Builder;
const Step = std.build.Step;
const Parser = lib.Parser;
const Interpreter = lib.Interpreter;
const SourceList = std.TailQueue(Source);
const FileSource = std.build.FileSource;
const GeneratedFile = std.build.GeneratedFile;
const BufferedWriter = io.BufferedWriter(4096, fs.File.Writer);
const FileContext = lib.context.StreamContext(BufferedWriter.Writer);

pub const FileList = std.ArrayListUnmanaged([]const u8);

pub const Source = struct {
    source: GeneratedFile,
    path: []const u8,
};

const log = std.log.scoped(.tangle_step);

vm: Interpreter = .{},
output_dir: ?[]const u8 = null,
builder: *Builder,
files: FileList = .{},
sources: SourceList = .{},
step: Step,

pub fn create(b: *Builder) *TangleStep {
    const self = b.allocator.create(TangleStep) catch @panic("Out of memory");
    self.* = .{
        .builder = b,
        .step = Step.init(.custom, "tangle", b.allocator, make),
    };
    return self;
}

pub fn addFile(self: *TangleStep, path: []const u8) void {
    self.files.append(self.builder.allocator, self.builder.dupe(path)) catch @panic(
        \\Out of memory
    );
}

pub fn getFileSource(self: *TangleStep, path: []const u8) FileSource {
    var it = self.sources.first;
    while (it) |node| : (it = node.next) {
        if (std.mem.eql(u8, node.data.path, path))
            return FileSource{ .generated = &node.data.source };
    }

    const node = self.builder.allocator.create(SourceList.Node) catch @panic(
        \\Out of memory
    );
    node.* = .{
        .data = .{
            .source = .{ .step = &self.step },
            .path = self.builder.dupe(path),
        },
    };

    self.sources.append(node);

    return FileSource{ .generated = &node.data.source };
}

fn make(step: *Step) anyerror!void {
    const self = @fieldParentPtr(TangleStep, "step", step);

    var hash = std.crypto.hash.blake2.Blake2b384.init(.{});

    for (self.files.items) |path| {
        const text = try fs.cwd().readFileAlloc(self.builder.allocator, path, 0x7fff_ffff);
        var p: Parser = .{ .it = .{ .bytes = text } };
        while (p.step(self.builder.allocator)) |working| {
            if (!working) break;
        } else |err| {
            const location = p.it.locationFrom(.{});
            log.err("line {d} col {d}: {s}", .{
                location.line,
                location.column,
                @errorName(err),
            });

            @panic("Failed parsing module");
        }

        hash.update(path);
        hash.update(text);

        const object = p.object(path);
        try self.vm.linker.objects.append(self.builder.allocator, object);
    }

    try self.vm.linker.link(self.builder.allocator);

    var digest: [48]u8 = undefined;
    hash.final(&digest);

    var basename: [64]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&basename, &digest);

    if (self.output_dir == null) {
        self.output_dir = try fs.path.join(self.builder.allocator, &.{
            self.builder.cache_root,
            "o",
            &basename,
        });
    }

    try fs.cwd().makePath(self.output_dir.?);

    var dir = try fs.cwd().openDir(self.output_dir.?, .{});
    defer dir.close();

    for (self.vm.linker.files.keys()) |path| {
        if (path.len > 2 and mem.eql(u8, path[0..2], "~/")) {
            return error.@"Absolute paths are not allowed";
        } else if (mem.indexOf(u8, path, "../") != null) {
            return error.@"paths containing ../ are not allowed";
        }

        if (fs.path.dirname(path)) |sub| try dir.makePath(sub);

        const file = try dir.createFile(path, .{ .truncate = true });
        defer file.close();

        var buffered: BufferedWriter = .{ .unbuffered_writer = file.writer() };
        const writer = buffered.writer();
        var context = FileContext.init(writer);
        try self.vm.callFile(self.builder.allocator, path, *FileContext, &context);
        try context.stream.writeByte('\n');
        try buffered.flush();

        var it = self.sources.first;
        while (it) |node| : (it = node.next) {
            if (mem.eql(u8, node.data.path, path)) {
                self.sources.remove(node);
                node.data.source.path = try fs.path.join(
                    self.builder.allocator,
                    &.{ self.output_dir.?, node.data.path },
                );
                break;
            }
        }
    }

    if (self.sources.first) |node| {
        log.err("file not found: {s}", .{node.data.path});
        var it = node.next;

        while (it) |next| {
            log.err("file not found: {s}", .{next.data.path});
        }

        @panic("Files not found");
    }
}
