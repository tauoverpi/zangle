![Zangle logo](assets/svg/zangle.svg?raw=true)


Zangle
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

Example
--------------------------------------------------------------------------------


    lang: zig esc: [[]] file: main.zig
    ----------------------------------

    const std = @import("std");
    const zangle = @import("zangle");

    const fs = std.fs;
    const io = std.io;
    const os = std.os;
    const mem = std.mem;
    const log = std.log.scoped(.zangle);

    pub const log_level = .info;

    const Allocator = std.mem.Allocator;

    pub fn main() anyerror!void {
        var instance = std.heap.GeneralPurposeAllocator(.{}){};
        const gpa = &instance.allocator;
        _ = gpa;

        const files = [[read file list from stdin and load files]];
        var vm = zangle.Interpreter.init(gpa, files) catch |e| {
            log.err("{s}", .{e});
            os.exit(1);
        };

        var dir = fs.cwd();

        for (vm.linker.files.keys()) |filename| {
            [[write file to disk]]
        }

        // lack of cleanup is intentional
    }


Command-line
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

    var tmp: [fs.MAX_PATH_BYTES]u8 = undefined;
    const path = if (!mem.startsWith(u8, filename, "~/")) filename else blk: {
        var fba = std.heap.FixedBufferAllocator.init(&tmp);
        break :blk try fs.path.join(&fba.allocator, &.{
            os.getenv("HOME") orelse return error.@"unable to find ~/",
            filename[2..],
        });
    };

    if (fs.path.dirname(path)) |dirname| {
        try dir.makePath(dirname);
    }

    log.info("writing file `{s}'", .{path});
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();

    var buffer = io.bufferedWriter(file.writer());

    vm.call(gpa, filename, buffer.writer()) catch |e| {
        log.err("{s}", .{e});
        os.exit(2);
    };

    try buffer.flush();


Node
================================================================================


    lang: js esc: none file: zangle.js
    ----------------------------------

    const fs = require('fs');
    const zangle = <<define and create the compiler object>>;
    const files = fs.readFileSync(0)
        .split(/\r?\n/)
        .map(filename => fs.readFileSync(filename));

    let vm = zangle.init(files);

    vm.files().forEach(filename => {
        fs.writeFile(filename, vm.call(filename), err => {
            if (err) return console.error(vm.getErrorMsg());
            console.log("written", filename);
        });
    });

TODO notes
================================================================================

File watcher
--------------------------------------------------------------------------------

Escape sequences for interactive execution of commands.

| function                | sequence              | reset     |
| --                      | --                    | --        |
| declare a scroll region | `ESC [ $from ; $to r` | `ESC [ r` |
| reset terminal          |                       | `ESC c`   |
| save cursor             | `ESC 7`               |           |
| restore cursor          | `ESC 8`               |           |

Having the results printed in the region above the command-line would be a
nice thing to have for interactive debugging (recompile, call, etc) along
with observing doctest output. However, changes to the screen would need to
be atomic so along the lines of `\e[r\e[48;0H\e[2K> call functi\e[1;47r\e[46;0H`
to update the command-line upon input.
