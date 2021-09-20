const std = @import("std");
const lib = @import("lib");
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const meta = std.meta;
const fs = std.fs;
const io = std.io;
const os = std.os;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const HashMap = std.AutoArrayHashMapUnmanaged;
const MultiArrayList = std.MultiArrayList;
const Tokenizer = lib.Tokenizer;
const Parser = lib.Parser;
const Linker = lib.Linker;
const Instruction = lib.Instruction;
const Interpreter = lib.Interpreter;

pub fn main() anyerror!void {
    var instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = &instance.allocator;

    const args = os.argv;

    var vm: Interpreter = .{};

    // options
    var allow_absolute_paths = false;
    var allow_shell_filters = false;
    var omit_trailing_newline = false;
    // end options

    for (args[1..]) |arg0| {
        const arg = mem.sliceTo(arg0, 0);

        if (mem.eql(u8, arg, "--allow-absolute-paths")) {
            allow_absolute_paths = true;
        } else if (mem.eql(u8, arg, "--allow-shell-filters")) {
            allow_shell_filters = true;
        } else if (mem.eql(u8, arg, "--omit-trailing-newline")) {
            omit_trailing_newline = true;
        } else {
            const text = try fs.cwd().readFileAlloc(gpa, arg, 0x7fff_ffff);
            const object = try Parser.parse(gpa, text);
            vm.linker.objects.append(gpa, object) catch return error.@"Exhausted memory";
        }
    }

    try vm.linker.link(gpa);

    for (vm.linker.files.keys()) |key| {
        std.log.debug("writing file: {s}", .{key});

        if (key[0] == '/' and !allow_absolute_paths) {
            return error.@"Absolute paths disabled; use --allow-absolute-paths to enable them.";
        }

        if (fs.path.dirname(key)) |dir| try fs.cwd().makePath(dir);

        var file = try fs.cwd().createFile(key, .{ .truncate = true });
        defer file.close();

        var render = Render.init(file.writer());

        try vm.callFile(gpa, key, *Render, &render);
        if (!omit_trailing_newline) try render.stream.writer().writeByte('\n');
        try render.stream.flush();
    }
}
const Render = struct {
    stream: Stream,

    pub const Stream = io.BufferedWriter(1024, std.fs.File.Writer);

    pub fn init(writer: fs.File.Writer) Render {
        return .{ .stream = .{ .unbuffered_writer = writer } };
    }

    pub fn write(self: *Render, text: []const u8, index: u32, nl: u16) !void {
        _ = index;
        const writer = self.stream.writer();
        try writer.writeAll(text);
        try writer.writeByteNTimes('\n', nl);
    }

    pub fn indent(self: *Render, len: u16) !void {
        const writer = self.stream.writer();
        try writer.writeByteNTimes(' ', len);
    }
};
