![Zangle logo](assets/svg/zangle.svg?raw=true)


ZANGLE                                                                     intro
================================================================================

Zangle is a tool for emitting code within markdown code blocks into files that a
regular toolchain can process with light preprocessing abilities. Code blocks
may be combined from one or more files and are emitted in the order they're
included in the document. This allows for a literate programming approach to
documenting both the design and implementation along with the program.

This program is unfinished and thus might not do what you expect at present.

TODO:

- [ ] Compile files presented on the command-line
- [ ] Pandoc markdown frontend (or just enough to work with it)
- [ ] Html5 frontend
- [ ] Zangle as a WebAssembly module
- [ ] Execution of `shell` commands
- [ ] Smarter instructions rather than one `write` per line
- [ ] File watcher with repl for calling document procedures
- rest of this list

ZANGLE                                                                   example
--------------------------------------------------------------------------------


    lang: zig esc: <<>> file: main.zig
    ----------------------------------

    const std = @import("std");
    const zangle = @import("zangle");

    const fs = std.fs;
    const io = std.io;
    const os = std.os;
    const log = std.log.scoped(.zangle);

    pub const log_level = .info;

    const Allocator = std.mem.Allocator;

    pub fn main() anyerror!void {
        var instance = std.heap.GeneralPurposeAllocator(.{}){};
        const gpa = &instance.allocator;
        _ = gpa;

        const files = <<read file list from stdin and load files>>;
        var vm = zangle.Interpreter.init(gpa, files) catch |e| {
            log.err("{s}", .{e});
            os.exit(1);
        };

        var dir = fs.cwd();

        for (vm.linker.files.keys()) |filename| {
            <<write file to disk>>
        }

        // lack of cleanup is intentional
    }


ZANGLE                                                              command-line
--------------------------------------------------------------------------------

File names are read from stdin.

    lang: zig esc: none tag: #read file list from stdin and load files
    ------------------------------------------------------------------

    blk: {
        const stdin = std.io.getStdIn();
        var buffer = io.bufferedReader(stdin.reader());
        const reader = buffer.reader();

        var list = std.ArrayList([]const u8).init(gpa);

        var path: [fs.MAX_PATH_BYTES]u8 = undefined;

        while (try reader.readUntilDelimiterOrEof(&path, '\n')) |filename| {
            log.info("loading file `{s}'", .{filename});
            try list.append(try fs.cwd().readFileAlloc(gpa, filename, 0x7fff_ffff));
        }

        break :blk list.toOwnedSlice();
    }

Writing files to disk.

    lang: zig esc: none tag: #write file to disk
    --------------------------------------------

    if (fs.path.dirname(filename)) |dirname| {
        log.info("creating path `{s}'", .{dirname});
        try dir.makePath(dirname);
    }

    log.info("writing file `{s}'", .{filename});
    var file = try dir.createFile(filename, .{ .truncate = true });
    defer file.close();

    var buffer = io.bufferedWriter(file.writer());

    vm.call(gpa, filename, buffer.writer()) catch |e| {
        log.err("{s}", .{e});
        os.exit(2);
    };

    try buffer.flush();


