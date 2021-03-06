![](assets/svg/logo.svg)

# Zangle

Zangle is a literate programming tool for extracting code fragments from
markdown and other types of text documents into separate files ready for
compilation.

NOTE: Currently zangle only supports markdown with a special header on
indented code blocks.

### Examples

Tangle all files within a document

    $ zangle tangle README.md

List all files in a document

    $ zangle ls README.md

Render the content of a tag to stdout

    $ zangle call README.md --tag='interpreter step'

Render a graph representing document structure

    $ zangle graph README.md | dot -Tpng -o grpah.png

Render a graph representing the structure of a single file output

    $ zangle graph README.md --file=lib/Linker.zig | dot -Tpng -o grpah.png

Find where given tags reside within output files

    $ zangle find README.md --tag='parser codegen' --tag='command-line parser'

Create a new literate document from existing files

    $ find src lib -name '*.zig' | zangle init build.zig --stdin > Zangle.md

## As a library

    lang: zig esc: none file: lib/lib.zig
    -------------------------------------

    pub const Tokenizer = @import("Tokenizer.zig");
    pub const Parser = @import("Parser.zig");
    pub const Linker = @import("Linker.zig");
    pub const Instruction = @import("Instruction.zig");
    pub const Interpreter = @import("Interpreter.zig");
    pub const context = @import("context.zig");
    pub const TangleStep = @import("TangleStep.zig");

    test {
        _ = Tokenizer;
        _ = Parser;
        _ = Linker;
        _ = Instruction;
        _ = Interpreter;
    }

## As a stand-alone application

    lang: zig esc: [[]] file: src/main.zig
    --------------------------------------

    const std = @import("std");
    const lib = @import("lib");
    const mem = std.mem;
    const assert = std.debug.assert;
    const testing = std.testing;
    const meta = std.meta;
    const fs = std.fs;
    const fmt = std.fmt;
    const io = std.io;
    const os = std.os;
    const math = std.math;
    const stdout = io.getStdOut().writer();
    const stdin = io.getStdIn().reader();

    const Allocator = std.mem.Allocator;
    const ArrayList = std.ArrayListUnmanaged;
    const HashMap = std.AutoArrayHashMapUnmanaged;
    const MultiArrayList = std.MultiArrayList;
    const Tokenizer = lib.Tokenizer;
    const Parser = lib.Parser;
    const Linker = lib.Linker;
    const Instruction = lib.Instruction;
    const Interpreter = lib.Interpreter;
    const GraphContext = @import("GraphContext.zig");
    const FindContext = @import("FindContext.zig");
    const BufferedWriter = io.BufferedWriter(4096, fs.File.Writer);
    const FileContext = lib.context.StreamContext(BufferedWriter.Writer);

    pub const log_level = .info;

    const Options = struct {
        allow_absolute_paths: bool = false,
        omit_trailing_newline: bool = false,
        list_files: bool = false,
        list_tags: bool = false,
        calls: []const FileOrTag = &.{},
        graph_text_colour: u24 = 0x000000,
        graph_background_colour: u24 = 0xffffff,
        graph_border_colour: u24 = 0x92abc9,
        graph_inherit_line_colour: bool = false,
        graph_line_gradient: u8 = 5,
        graph_colours: []const u24 = &.{
            0xdf4d77,
            0x2288ed,
            0x94bd76,
            0xc678dd,
            0x61aeee,
            0xe3bd79,
        },
        command: Command,
        files: []const []const u8 = &.{},

        pub const FileOrTag = union(enum) {
            file: []const u8,
            tag: []const u8,
        };
    };

    [[command-line parser]]

    pub fn main() void {
        run() catch |err| {
            log.err("{s}", .{@errorName(err)});
            os.exit(1);
        };
    }

    pub fn run() !void {
        var vm: Interpreter = .{};
        var instance = std.heap.GeneralPurposeAllocator(.{}){};
        const gpa = instance.allocator();

        var options = (try parseCli(gpa, &vm.linker.objects)) orelse return;

        const n_objects = vm.linker.objects.items.len;
        const plural: []const u8 = if (n_objects == 1) "object" else "objects";

        log.info("linking {d} {s}...", .{ n_objects, plural });

        try vm.linker.link(gpa);

        log.debug("processing command {s}", .{@tagName(options.command)});

        switch (options.command) {
            .help => unreachable, // handled in parseCli

            .ls => {
                var buffered = io.bufferedWriter(stdout);
                const writer = buffered.writer();

                if (!options.list_files) options.list_files = !options.list_tags;

                if (options.list_tags) for (vm.linker.procedures.keys()) |path| {
                    try writer.writeAll(path);
                    try writer.writeByte('\n');
                };

                if (options.list_files) for (vm.linker.files.keys()) |path| {
                    try writer.writeAll(path);
                    try writer.writeByte('\n');
                };

                try buffered.flush();
            },

            .call => {
                var buffered: BufferedWriter = .{ .unbuffered_writer = stdout };
                var context = FileContext.init(buffered.writer());

                for (options.calls) |call| switch (call) {
                    .file => |file| {
                        log.debug("calling file {s}", .{file});
                        try vm.callFile(gpa, file, *FileContext, &context);
                        if (!options.omit_trailing_newline) try context.stream.writeByte('\n');
                    },
                    .tag => |tag| {
                        log.debug("calling tag {s}", .{tag});
                        try vm.call(gpa, tag, *FileContext, &context);
                    },
                };

                try buffered.flush();
            },

            .find => for (options.calls) |call| switch (call) {
                .file => unreachable, // not an option for find
                .tag => |tag| {
                    log.debug("finding paths to tag {s}", .{tag});
                    for (vm.linker.files.keys()) |file| {
                        var context = FindContext.init(gpa, file, tag, stdout);
                        try vm.callFile(gpa, file, *FindContext, &context);
                        try context.stream.flush();
                    }
                },
            },

            .graph => {
                var context = GraphContext.init(gpa, stdout);

                try context.begin(.{
                    .border = options.graph_border_colour,
                    .background = options.graph_background_colour,
                    .text = options.graph_text_colour,
                    .colours = options.graph_colours,
                    .inherit = options.graph_inherit_line_colour,
                    .gradient = options.graph_line_gradient,
                });

                if (options.calls.len != 0) {
                    for (options.calls) |call| switch (call) {
                        .tag => unreachable, // not an option for graph
                        .file => |file| {
                            log.debug("rendering graph for file {s}", .{file});
                            try vm.callFile(gpa, file, *GraphContext, &context);
                        },
                    };
                } else {
                    for (vm.linker.files.keys()) |path| {
                        try vm.callFile(gpa, path, *GraphContext, &context);
                    }

                    for (vm.linker.procedures.keys()) |proc| {
                        if (!context.target.contains(proc.ptr)) {
                            try vm.call(gpa, proc, *GraphContext, &context);
                        }
                    }
                }

                try context.end();
            },

            .tangle => for (vm.linker.files.keys()) |path| {
                const file = try createFile(path, options);
                defer file.close();

                var buffered: BufferedWriter = .{ .unbuffered_writer = file.writer() };
                var context = FileContext.init(buffered.writer());

                try vm.callFile(gpa, path, *FileContext, &context);
                if (!options.omit_trailing_newline) try context.stream.writeByte('\n');
                try buffered.flush();
            },

            .init => for (options.files) |path, index| {
                try import(path, stdout);
                if (index + 1 != options.files.len) try stdout.writeByte('\n');
            },
        }
    }

    [[create file with path wrapper]]
    [[render text indented by four spaces]]
    [[method for import a file and emit a code block targeting it]]

# Command-line interface

    lang: zig esc: none tag: #command-line parser
    ---------------------------------------------

    const Command = enum {
        help,
        tangle,
        ls,
        call,
        graph,
        find,
        init,

        pub const map = std.ComptimeStringMap(Command, .{
            .{ "help", .help },
            .{ "tangle", .tangle },
            .{ "ls", .ls },
            .{ "call", .call },
            .{ "graph", .graph },
            .{ "find", .find },
            .{ "init", .init },
        });
    };

    const Flag = enum {
        allow_absolute_paths,
        omit_trailing_newline,
        file,
        tag,
        list_tags,
        list_files,
        graph_border_colour,
        graph_inherit_line_colour,
        graph_colours,
        graph_background_colour,
        graph_line_gradient,
        graph_text_colour,
        @"--",
        stdin,

        pub const map = std.ComptimeStringMap(Flag, .{
            .{ "--allow-absolute-paths", .allow_absolute_paths },
            .{ "--omit-trailing-newline", .omit_trailing_newline },
            .{ "--file=", .file },
            .{ "--tag=", .tag },
            .{ "--list-tags", .list_tags },
            .{ "--list-files", .list_files },
            .{ "--graph-border-colour=", .graph_border_colour },
            .{ "--graph-colours=", .graph_colours },
            .{ "--graph-background-colour=", .graph_background_colour },
            .{ "--graph-text-colour=", .graph_text_colour },
            .{ "--graph-inherit-line-colour", .graph_inherit_line_colour },
            .{ "--graph-line-gradient=", .graph_line_gradient },
            .{ "--", .@"--" },
            .{ "--stdin", .stdin },
        });
    };

    const tangle_help =
        \\Usage: zangle tangle [options] [files]
        \\
        \\  --allow-absolute-paths   Allow writing file blocks with absolute paths
        \\  --omit-trailing-newline  Do not print a trailing newline at the end of a file block
    ;

    const ls_help =
        \\Usage: zangle ls [files]
        \\
        \\  --list-files  (default) List all file output paths in the document
        \\  --list-tags   List all tags in the document
    ;

    const call_help =
        \\Usage: zangle call [options] [files]
        \\
        \\  --file=[filepath]  Render file block to stdout
        \\  --tag=[tagname]    Render tag block to stdout
    ;

    const find_help =
        \\Usage: zangle find [options] [files]
        \\
        \\  --tag=[tagname]    Find the location of the given tag in the literate document and output files
    ;

    const graph_help =
        \\Usage: zangle graph [files]
        \\
        \\  --file=[filepath]                    Render the graph for the given file
        \\  --graph-border=[#rrggbb]             Set item border colour
        \\  --graph-colours=[#rrggbb,...]        Set spline colours
        \\  --graph-background-colour=[#rrggbb]  Set the background colour of the graph
        \\  --graph-text-colour=[#rrggbb]        Set node label text colour
        \\  --graph-inherit-line-colour          Borders inherit their colour from the choden line colour
        \\  --graph-line-gradient=[number]       Set the gradient level
    ;

    const init_help =
        \\Usage: zangle init [files]
        \\  --stdin  Read file names from stdin
    ;

    const log = std.log;

    fn helpGeneric() void {
        log.info(
            \\{s}
            \\
            \\{s}
            \\
            \\{s}
            \\
            \\{s}
            \\
            \\{s}
        , .{
            tangle_help,
            ls_help,
            call_help,
            graph_help,
            init_help,
        });
    }

    fn help(com: ?Command, name: ?[]const u8) void {
        const command = com orelse {
            helpGeneric();
            log.err("I don't know how to handle the given command '{s}'", .{name.?});
            return;
        };

        switch (command) {
            .help => helpGeneric(),
            .tangle => log.info(tangle_help, .{}),
            .ls => log.info(ls_help, .{}),
            .call => log.info(call_help, .{}),
            .graph => log.info(graph_help, .{}),
            .find => log.info(find_help, .{}),
            .init => log.info(init_help, .{}),
        }
    }

    fn parseCli(gpa: Allocator, objects: *Linker.Object.List) !?Options {
        var options: Options = .{ .command = undefined };
        const args = os.argv;

        if (args.len < 2) {
            help(.help, null);
            return error.@"Missing command name";
        }

        const command_name = mem.sliceTo(args[1], 0);
        const command = Command.map.get(command_name);

        if (args.len < 3 or command == null or command.? == .help) {
            help(command, command_name);
            if (command) |com| {
                switch (com) {
                    .help => return null,
                    else => return error.@"Not enough arguments",
                }
            } else {
                return error.@"Invalid command";
            }
        }

        var interpret_flags_as_files: bool = false;
        var calls = std.ArrayList(Options.FileOrTag).init(gpa);
        var files = std.ArrayList([]const u8).init(gpa);
        var graph_colours = std.ArrayList(u24).init(gpa);
        var graph_colours_set = false;
        var files_on_stdin = false;

        options.command = command.?;

        for (args[2..]) |arg0| {
            const arg = mem.sliceTo(arg0, 0);
            if (arg.len == 0) return error.@"Zero length argument";

            if (arg[0] == '-' and !interpret_flags_as_files) {
                errdefer log.err("I don't know how to parse the given option '{s}'", .{arg});

                log.debug("processing {s} flag '{s}'", .{ @tagName(options.command), arg });

                const split = (mem.indexOfScalar(u8, arg, '=') orelse (arg.len - 1)) + 1;
                const flag = Flag.map.get(arg[0..split]) orelse {
                    return error.@"Unknown option";
                };

                switch (options.command) {
                    .help => unreachable,

                    .ls => switch (flag) {
                        .list_files => options.list_files = true,
                        .list_tags => options.list_tags = true,
                        else => return error.@"Unknown command-line flag",
                    },

                    .call => switch (flag) {
                        .file => try calls.append(.{ .file = arg[split..] }),
                        .tag => try calls.append(.{ .tag = arg[split..] }),
                        else => return error.@"Unknown command-line flag",
                    },

                    .find => switch (flag) {
                        .tag => try calls.append(.{ .tag = arg[split..] }),
                        else => return error.@"Unknown command-line flag",
                    },

                    .graph => switch (flag) {
                        .file => try calls.append(.{ .file = arg[split..] }),
                        .graph_border_colour => options.graph_border_colour = try parseColour(arg[split..]),
                        .graph_background_colour => options.graph_background_colour = try parseColour(arg[split..]),
                        .graph_text_colour => options.graph_text_colour = try parseColour(arg[split..]),
                        .graph_inherit_line_colour => options.graph_inherit_line_colour = true,
                        .graph_line_gradient => options.graph_line_gradient = fmt.parseInt(u8, arg[split..], 10) catch {
                            return error.@"Invalid value specified, expected a number between 0-255 (inclusive)";
                        },

                        .graph_colours => {
                            var it = mem.tokenize(u8, arg[split..], ",");

                            while (it.next()) |item| {
                                try graph_colours.append(try parseColour(item));
                            }

                            graph_colours_set = true;
                        },

                        else => return error.@"Unknown command-line flag",
                    },

                    .tangle => switch (flag) {
                        .allow_absolute_paths => options.allow_absolute_paths = true,
                        .omit_trailing_newline => options.omit_trailing_newline = true,
                        .@"--" => interpret_flags_as_files = true,
                        else => return error.@"Unknown command-line flag",
                    },

                    .init => switch (flag) {
                        .stdin => files_on_stdin = true,
                        else => return error.@"Unknown command-line flag",
                    },
                }
            } else if (options.command != .init) {
                std.log.info("compiling {s}", .{arg});
                const text = try fs.cwd().readFileAlloc(gpa, arg, 0x7fff_ffff);

                var p: Parser = .{ .it = .{ .bytes = text } };

                while (p.step(gpa)) |working| {
                    if (!working) break;
                } else |err| {
                    const location = p.it.locationFrom(.{});
                    log.err("line {d} col {d}: {s}", .{
                        location.line,
                        location.column,
                        @errorName(err),
                    });

                    os.exit(1);
                }

                const object = p.object(arg);

                objects.append(gpa, object) catch return error.@"Exhausted memory";
            } else {
                files.append(arg) catch return error.@"Exhausted memory";
            }
        }

        if (files_on_stdin) {
            const err = error.@"Exhausted memory";
            while (stdin.readUntilDelimiterOrEofAlloc(gpa, '\n', fs.MAX_PATH_BYTES) catch return err) |path| {
                files.append(path) catch return error.@"Exhausted memory";
            }
        }

        if (options.command == .init and files.items.len == 0) {
            return error.@"No files to import specified";
        }

        options.calls = calls.toOwnedSlice();
        options.files = files.toOwnedSlice();
        if (graph_colours_set) {
            options.graph_colours = graph_colours.toOwnedSlice();
        }
        return options;
    }

    fn parseColour(text: []const u8) !u24 {
        if (text.len == 7) {
            if (text[0] != '#') return error.@"Invalid colour spexification, expected '#'";
            return fmt.parseInt(u24, text[1..], 16) catch error.@"Colour specification is not a valid 24-bit hex number";
        } else {
            return error.@"Invalid hex colour specification length; expecting a 6 hex digit colour prefixed with a '#'";
        }
    }

## Loading files

    lang: zig esc: none tag: #create file with path wrapper
    -------------------------------------------------------

    fn createFile(path: []const u8, options: Options) !fs.File {
        var tmp: [fs.MAX_PATH_BYTES]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&tmp);
        var filename = path;
        var absolute = false;

        if (filename.len > 2 and mem.eql(u8, filename[0..2], "~/")) {
            filename = try fs.path.join(fba.allocator(), &.{
                os.getenv("HOME") orelse return error.@"unable to find ~/",
                filename[2..],
            });
        }

        if (path[0] == '/' or path[0] == '~') {
            if (!options.allow_absolute_paths) {
                return error.@"Absolute paths disabled; use --allow-absolute-paths to enable them.";
            } else {
                absolute = true;
            }
        }

        if (fs.path.dirname(filename)) |dir| fs.cwd().makePath(dir) catch {};

        if (absolute) {
            log.warn("writing file with absolute path: {s}", .{filename});
        } else {
            log.info("writing file: {s}", .{filename});
        }
        return try fs.cwd().createFile(filename, .{ .truncate = true });
    }

## Setting up existing projects

    lang: zig esc: none tag: #method for import a file and emit a code block targeting it
    -------------------------------------------------------------------------------------

    fn import(path: []const u8, writer: anytype) !void {
        var file = try fs.cwd().openFile(path, .{});
        defer file.close();

        const last = mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        const lang = if (mem.lastIndexOfScalar(u8, path[last..], '.')) |index|
            path[last + index + 1 ..]
        else
            "unknown";

        var buffered = io.bufferedReader(file.reader());
        var counting = io.countingWriter(writer);
        try writer.writeByteNTimes('#', math.clamp(mem.count(u8, path[1..], "/"), 0, 5) + 1);
        try writer.writeByte(' ');
        try writer.writeAll(path);
        try writer.writeAll(" \n\n    ");
        try counting.writer().print("lang: {s} esc: none file: {s}", .{ lang, path });
        try writer.writeByte('\n');
        try writer.writeAll("    ");
        try writer.writeByteNTimes('-', counting.bytes_written);
        try writer.writeAll("\n\n");
        try indent(buffered.reader(), writer);
    }

<!-- -->

    lang: zig esc: none tag: #render text indented by four spaces
    -------------------------------------------------------------

    fn indent(reader: anytype, writer: anytype) !void {
        var buffer: [1 << 12]u8 = undefined;
        var nl = true;

        while (true) {
            const len = try reader.read(&buffer);
            if (len == 0) return;
            const slice = buffer[0..len];
            var last: usize = 0;
            while (mem.indexOfScalarPos(u8, slice, last, '\n')) |index| {
                if (nl) try writer.writeAll("    ");
                try writer.writeAll(slice[last..index]);
                try writer.writeByte('\n');
                nl = true;
                last = index + 1;
            } else if (slice[last..].len != 0) {
                if (nl) try writer.writeAll("    ");
                try writer.writeAll(slice[last..]);
                nl = false;
            }
        }
    }

    test "indent text block" {
        const source =
            \\pub fn main() !void {
            \\    return;
            \\}
        ;
        var buffer: [1024 * 4]u8 = undefined;
        var in = io.fixedBufferStream(source);
        var out = io.fixedBufferStream(&buffer);

        try indent(in.reader(), out.writer());

        try testing.expectEqualStrings(
            \\    pub fn main() !void {
            \\        return;
            \\    }
        , out.getWritten());
    }

# Build step

    lang: zig esc: none file: lib/TangleStep.zig
    --------------------------------------------

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

# Machine

Zangle represents documents as bytecode programs consisting mostly of `write`
instructions to render code line-by-line with respect to the tag's indentation
along with block writes for weaving literate source documents. Other
instructions handle the order in which to tangle blocks of code such as
`call` which embeds one block in another and `jmp` which threads adjacent
blocks (by tag name) together into one.

## Instructions

Each instruction consists of an 8-bit opcode along with a 64-bit data argument.

    lang: zig esc: [[]] file: lib/Instruction.zig
    ---------------------------------------------

    const std = @import("std");
    const assert = std.debug.assert;

    const Instruction = @This();

    opcode: Opcode,
    data: Data,

    pub const List = std.MultiArrayList(Instruction);
    pub const Opcode = enum(u8) {
        ret,
        call,
        jmp,
        shell,
        write,
    };

    pub const Data = extern union {
        ret: Ret,
        jmp: Jmp,
        call: Call,
        shell: Shell,
        write: Write,

        [[instruction list]]
    };

    comptime {
        assert(@sizeOf(Data) == 8);
    }

### Ret

Pops the location and module in which the matching `call` instruction
originated from. If any filters have been registered in the calling context
then this instruction marks the end of the context and executes the action
bound. The payload includes the index and length of the current procedure
name which is provided as a parameter to rendering contexts.

    lang: zig esc: none tag: #instruction list
    ------------------------------------------

    pub const Ret = extern struct {
        start: u32,
        len: u16,
        pad: u16 = 0,
    };

<!-- -->

    lang: zig esc: none tag: #parser codegen
    ----------------------------------------

    fn emitRet(
        p: *Parser,
        gpa: Allocator,
        params: Instruction.Data.Ret,
    ) !void {
        log.debug("emitting ret", .{});
        try p.program.append(gpa, .{
            .opcode = .ret,
            .data = .{ .ret = params },
        });
    }

Execution of the `ret` instruction.

`ret` will invoke the `ret` method of the render context upon returning from
a normal procedure and `terminate` upon reaching the end of the program. Of
the parameters, `module` is that of the caller and `ip` points to the next
instruction to be run which a rendering context can use to calculate the
entry-point of the procedure.

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    fn execRet(vm: *Interpreter, comptime T: type, data: Instruction.Data.Ret, eval: T) Child(T).Error!bool {
        const name = vm.linker.objects.items[vm.module - 1]
            .text[data.start .. data.start + data.len];

        if (vm.stack.popOrNull()) |location| {
            const mod = vm.module;
            const ip = vm.ip;

            vm.ip = location.value.ip;
            vm.module = location.value.module;
            vm.indent -= location.value.indent;

            if (@hasDecl(Child(T), "ret")) try eval.ret(
                vm,
                name,
            );
            log.debug("[mod {d} ip {x:0>8}] ret(mod {d}, ip {x:0>8}, indent {d}, identifier '{s}')", .{
                mod,
                ip,
                vm.module,
                vm.ip,
                vm.indent,
                name,
            });

            return true;
        }

        if (@hasDecl(Child(T), "terminate")) try eval.terminate(vm, name);
        log.debug("[mod {d} ip {x:0>8}] terminate(identifier '{s}')", .{
            vm.module,
            vm.ip,
            name,
        });

        return false;
    }

### Jmp

Jumps to the specified address of the given module without pushing to the
return stack. This instruction is primarily used to thread blocks with the
same tag together across files in the order in which they occur within the
literate source. If the target module is 0 then it's interpreted as being
local to the current module.


    lang: zig esc: none tag: #instruction list
    ------------------------------------------

    pub const Jmp = extern struct {
        address: u32,
        module: u16,
        generation: u16 = 0,
    };

<!-- -->

    lang: zig esc: none tag: #parser codegen
    ----------------------------------------

    fn writeJmp(
        p: *Parser,
        location: u32,
        params: Instruction.Data.Jmp,
    ) !void {
        log.debug("writing jmp over {x:0>8} to {x:0>8}", .{
            location,
            params.address,
        });
        p.program.set(location, .{
            .opcode = .jmp,
            .data = .{ .jmp = params },
        });
    }

<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    fn execJmp(vm: *Interpreter, comptime T: type, data: Instruction.Data.Jmp, eval: T) Child(T).Error!void {
        const mod = vm.module;
        const ip = vm.ip;

        if (data.module != 0) {
            vm.module = data.module;
        }

        vm.ip = data.address;

        if (@hasDecl(Child(T), "jmp")) try eval.jmp(vm, data.address);
        if (@hasDecl(Child(T), "write")) try eval.write(vm, "\n", 0);

        log.debug("[mod {d} ip {x:0>8}] jmp(mod {d}, address {x:0>8})", .{
            mod,
            ip,
            vm.module,
            vm.ip,
        });

        vm.last_is_newline = true;
    }

### Call

Saves the module context, instruction pointer, and calling context on the
return stack before jumping to the specified address within the given module.
If the target module is 0 then it's interpreted as being local to the
current module.

    lang: zig esc: none tag: #instruction list
    ------------------------------------------

    pub const Call = extern struct {
        address: u32,
        module: u16,
        indent: u16,
    };

<!-- -->

    lang: zig esc: none tag: #parser codegen
    ----------------------------------------

    fn emitCall(
        p: *Parser,
        gpa: Allocator,
        tag: []const u8,
        params: Instruction.Data.Call,
    ) !void {
        log.debug("emitting call to {s}", .{tag});
        const result = try p.symbols.getOrPut(gpa, tag);
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        }

        try result.value_ptr.append(gpa, @intCast(u32, p.program.len));

        try p.program.append(gpa, .{
            .opcode = .call,
            .data = .{ .call = params },
        });
    }

<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    pub const CallError = error{
        @"Cyclic reference detected",
        OutOfMemory,
    };

    fn execCall(
        vm: *Interpreter,
        comptime T: type,
        data: Instruction.Data.Call,
        gpa: Allocator,
        eval: T,
    ) (CallError || Child(T).Error)!void {
        if (vm.stack.contains(vm.ip)) {
            return error.@"Cyclic reference detected";
        }

        const mod = vm.module;
        const ip = vm.ip;

        try vm.stack.put(gpa, vm.ip, .{
            .ip = vm.ip,
            .indent = data.indent,
            .module = vm.module,
        });

        vm.indent += data.indent;
        vm.ip = data.address;

        if (data.module != 0) {
            vm.module = data.module;
        }

        if (@hasDecl(Child(T), "call")) try eval.call(vm);
        log.debug("[mod {d} ip {x:0>8}] call(mod {d}, ip {x:0>8})", .{
            mod,
            ip - 1,
            vm.module,
            vm.ip,
        });
    }

### Shell

Appends a calling context to the next `call` instruction with a shell command
for filtering rendered content within the given block.

    lang: zig esc: none tag: #instruction list
    ------------------------------------------

    pub const Shell = extern struct {
        command: u32,
        module: u16,
        len: u8,
        pad: u8,
    };


<!-- -->

    lang: zig esc: none tag: #parser codegen
    ----------------------------------------

    fn emitShell(
        p: *Parser,
        gpa: Allocator,
        params: Instruction.Data.Shell,
    ) !void {
        log.debug("emitting shell command", .{});
        try p.program.append(gpa, .{
            .opcode = .shell,
            .data = .{ .shell = params },
        });
    }

<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    fn execShell(
        vm: *Interpreter,
        comptime T: type,
        data: Instruction.Data.Shell,
        text: []const u8,
        eval: T,
    ) void {
        if (@hasDecl(Child(T), "shell")) try eval.shell(vm);
        _ = vm;
        _ = data;
        _ = text;
        @panic("TODO: implement shell");
    }

### Write

Writes lines of text from the current module to the output stream. If a
calling context is present then the output is written to a buffer instead.
A trail of newline characters is emitted after the text as specified in the
`nl` field of the 64-bit data block.

    lang: zig esc: none tag: #instruction list
    ------------------------------------------

    pub const Write = extern struct {
        start: u32,
        len: u16,
        nl: u16,
    };

<!-- -->

    lang: zig esc: none tag: #parser codegen
    ----------------------------------------

    fn emitWrite(
        p: *Parser,
        gpa: Allocator,
        params: Instruction.Data.Write,
    ) !void {
        log.debug("emitting write {x:0>8} len {d} nl {d}", .{
            params.start,
            params.len,
            params.nl,
        });
        try p.program.append(gpa, .{
            .opcode = .write,
            .data = .{ .write = params },
        });
    }

<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    fn execWrite(
        vm: *Interpreter,
        comptime T: type,
        data: Instruction.Data.Write,
        text: []const u8,
        eval: T,
    ) Child(T).Error!void {
        if (vm.should_indent and vm.last_is_newline) {
            if (@hasDecl(Child(T), "indent")) try eval.indent(vm);
            log.debug("[mod {d} ip {x:0>8}] indent(len {d})", .{
                vm.module,
                vm.ip,
                vm.indent,
            });
        } else {
            vm.should_indent = true;
        }

        if (@hasDecl(Child(T), "write")) try eval.write(
            vm,
            text[data.start .. data.start + data.len],
            data.nl,
        );

        log.debug("[mod {d} ip {x:0>8}] write(text {*}, index {x:0>8}, len {d}, nl {d}): {s}", .{
            vm.module,
            vm.ip,
            text,
            data.start,
            data.len,
            data.nl,
            text[data.start .. data.start + data.len],
        });

        vm.last_is_newline = data.nl != 0;
    }

## Interpreter contexts

Rendering is handled by passing a context in which to run the program.

### Test context

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    const Test = struct {
        stream: Stream,

        pub const Error = Stream.WriteError;

        pub const Stream = std.io.FixedBufferStream([]u8);

        pub fn write(self: *Test, vm: *Interpreter, text: []const u8, nl: u16) !void {
            _ = vm;
            const writer = self.stream.writer();
            try writer.writeAll(text);
            try writer.writeByteNTimes('\n', nl);
        }

        pub fn indent(self: *Test, vm: *Interpreter) !void {
            _ = vm;
            const writer = self.stream.writer();
            try writer.writeByteNTimes(' ', vm.indent);
        }

        pub fn expect(self: *Test, expected: []const u8) !void {
            try testing.expectEqualStrings(expected, self.stream.getWritten());
        }
    };

### Stream context

    lang: zig esc: none file: lib/context.zig
    -----------------------------------------

    const lib = @import("lib.zig");

    const Interpreter = lib.Interpreter;

    pub fn StreamContext(comptime Writer: type) type {
        return struct {
            stream: Writer,

            const Self = @This();

            pub const Error = Writer.Error;

            pub fn init(writer: Writer) Self {
                return .{ .stream = writer };
            }

            pub fn write(self: *Self, vm: *Interpreter, text: []const u8, nl: u16) !void {
                _ = vm;
                try self.stream.writeAll(text);
                try self.stream.writeByteNTimes('\n', nl);
            }

            pub fn indent(self: *Self, vm: *Interpreter) !void {
                try self.stream.writeByteNTimes(' ', vm.indent);
            }
        };
    }

### Find context

    lang: zig esc: none file: src/FindContext.zig
    ---------------------------------------------

    const std = @import("std");
    const lib = @import("lib");
    const io = std.io;
    const fs = std.fs;
    const mem = std.mem;

    const ArrayList = std.ArrayListUnmanaged;
    const Allocator = std.mem.Allocator;
    const Interpreter = lib.Interpreter;
    const FindContext = @This();

    stream: Stream,
    line: u32 = 1,
    column: u32 = 1,
    stack: Stack = .{},
    filename: []const u8,
    tag: []const u8,
    gpa: Allocator,

    const log = std.log.scoped(.find_context);

    pub const Error = error{OutOfMemory} || std.os.WriteError;

    pub const Stream = io.BufferedWriter(1024, std.fs.File.Writer);

    pub const Stack = ArrayList(Location);

    pub const Location = struct {
        line: u32,
        column: u32,
    };

    pub fn init(gpa: Allocator, file: []const u8, tag: []const u8, writer: fs.File.Writer) FindContext {
        return .{
            .stream = .{ .unbuffered_writer = writer },
            .filename = file,
            .tag = tag,
            .gpa = gpa,
        };
    }

    pub fn write(self: *FindContext, vm: *Interpreter, text: []const u8, nl: u16) !void {
        _ = vm;
        if (nl == 0) {
            self.column += @intCast(u32, text.len);
        } else {
            self.line += @intCast(u32, nl);
            self.column = @intCast(u32, text.len + 1);
        }
    }

    pub fn call(self: *FindContext, vm: *Interpreter) !void {
        _ = vm;

        try self.stack.append(self.gpa, .{
            .line = self.line,
            .column = self.column,
        });
    }

    pub fn ret(self: *FindContext, vm: *Interpreter, name: []const u8) !void {
        _ = name;

        const writer = self.stream.writer();
        const location = self.stack.pop();
        const procedure = vm.linker.procedures.get(name).?;
        const obj = vm.linker.objects.items[procedure.module - 1];

        if (mem.eql(u8, self.tag, name)) try writer.print(
            \\{s}: line {d} column {d} '{s}' -> line {d} column {d} '{s}' ({d} lines)
            \\
        , .{
            self.tag,
            procedure.location.line,
            procedure.location.column,
            obj.name,
            location.line,
            location.column,
            self.filename,
            self.line - location.line,
        });
    }

### Graph context

    lang: zig esc: [[]] file: src/GraphContext.zig
    ----------------------------------------------

    const std = @import("std");
    const lib = @import("lib");
    const io = std.io;
    const fs = std.fs;
    const assert = std.debug.assert;

    const Allocator = std.mem.Allocator;
    const ArrayList = std.ArrayListUnmanaged;
    const HashMap = std.AutoHashMapUnmanaged;
    const Interpreter = lib.Interpreter;
    const GraphContext = @This();

    stream: Stream,
    stack: Stack = .{},
    omit: Omit = .{},
    gpa: Allocator,
    colour: u8 = 0,
    target: Target = .{},
    text_colour: u24 = 0,
    inherit: bool = false,
    colours: []const u24 = &.{},
    gradient: u8 = 5,

    pub const Error = error{OutOfMemory} || std.os.WriteError;

    pub const Stack = ArrayList(Layer);
    pub const Layer = struct {
        list: ArrayList([]const u8) = .{},
    };

    pub const Target = HashMap([*]const u8, u8);

    pub const Omit = HashMap(Pair, void);
    pub const Pair = struct {
        from: [*]const u8,
        to: [*]const u8,
    };

    pub const Stream = io.BufferedWriter(1024, std.fs.File.Writer);

    pub fn init(gpa: Allocator, writer: fs.File.Writer) GraphContext {
        return .{
            .stream = .{ .unbuffered_writer = writer },
            .gpa = gpa,
        };
    }

    pub const GraphOptions = struct {
        border: u24 = 0,
        background: u24 = 0,
        text: u24 = 0,
        colours: []const u24 = &.{},
        inherit: bool = false,
        gradient: u8 = 0,
    };

    pub fn begin(self: *GraphContext, options: GraphOptions) !void {
        try self.stream.writer().print(
            \\graph G {{
            \\    bgcolor = "#{[background]x:0>6}";
            \\    overlap = false;
            \\    rankdir = LR;
            \\    concentrate = true;
            \\    node[shape = rectangle, color = "#{[border]x:0>6}"];
            \\
        , .{
            .background = options.background,
            .border = options.border,
        });

        try self.stack.append(self.gpa, .{});

        self.colours = options.colours;
        self.text_colour = options.text;
        self.inherit = options.inherit;
        self.gradient = options.gradient;
    }

    pub fn end(self: *GraphContext) !void {
        try self.stream.writer().writeAll("}\n");
        try self.stream.flush();
    }

    pub fn call(self: *GraphContext, vm: *Interpreter) !void {
        _ = vm;
        try self.stack.append(self.gpa, .{});
    }

    pub fn ret(self: *GraphContext, vm: *Interpreter, name: []const u8) !void {
        _ = vm;

        try self.render(name);

        var old = self.stack.pop();
        old.list.deinit(self.gpa);

        try self.stack.items[self.stack.items.len - 1].list.append(self.gpa, name);
    }

    pub fn terminate(self: *GraphContext, vm: *Interpreter, name: []const u8) !void {
        _ = vm;
        try self.render(name);

        self.stack.items[0].list.clearRetainingCapacity();

        assert(self.stack.items.len == 1);
    }

    [[graph context render node]]

<!-- -->

    lang: zig esc: [[]] tag: #graph context render node
    ---------------------------------------------------

    fn render(self: *GraphContext, name: []const u8) !void {
        const writer = self.stream.writer();
        const sub_nodes = self.stack.items[self.stack.items.len - 1].list.items;

        var valid: usize = 0;
        for (sub_nodes) |sub| {
            if (!self.omit.contains(.{ .from = name.ptr, .to = sub.ptr })) {
                valid += 1;
            }
        }

        const theme = try self.target.getOrPut(self.gpa, name.ptr);
        if (!theme.found_existing) {
            theme.value_ptr.* = self.colour;
            defer self.colour +%= 1;

            const selected = if (self.colours.len == 0)
                self.colour
            else
                self.colours[self.colour % self.colours.len];

            if (self.inherit) {
                try writer.print(
                    \\    "{[name]s}"[fontcolor = "#{[colour]x:0>6}", color = "#{[inherit]x:0>6}"];
                    \\
                , .{
                    .name = name,
                    .colour = self.text_colour,
                    .inherit = selected,
                });
            } else {
                try writer.print(
                    \\    "{[name]s}"[fontcolor = "#{[colour]x:0>6}"];
                    \\
                , .{
                    .name = name,
                    .colour = self.text_colour,
                });
            }
        }

        for (sub_nodes) |sub| {
            const entry = try self.omit.getOrPut(self.gpa, .{
                .from = name.ptr,
                .to = sub.ptr,
            });

            if (!entry.found_existing) {
                const to = self.target.get(sub.ptr).?;
                const from = self.target.get(name.ptr).?;

                const selected: struct { from: u24, to: u24 } = if (self.colours.len == 0) .{
                    .from = 0,
                    .to = 0,
                } else .{
                    .from = self.colours[from % self.colours.len],
                    .to = self.colours[to % self.colours.len],
                };

                try writer.print(
                    \\    "{s}" -- "{s}" [color = "
                , .{ name, sub });

                [[graph context gradient]]

                try writer.print(
                    \\#{x:0>6}"];
                    \\
                , .{selected.to});
            }
        }
    }

#### Gradients

Node graphs can be rather difficult when they result in a directed acyclic
graph instead of the usual tree structure that most projects will have; for
those situations, targeted colour may not be enough to trace paths correctly.
However, gradients offer enough variation to avoid the problem in most cases
and they tend to look good most of the time making them a good default.

The implementation interpolates between the parent and child node colours
and inserts the results in the node's `color` list to create the effect.

    lang: zig esc: none tag: #graph context gradient
    ------------------------------------------------

    if (self.gradient != 0) {
        var i: i24 = 0;
        const r: i32 = @truncate(u8, selected.from >> 16);
        const g: i32 = @truncate(u8, selected.from >> 8);
        const b: i32 = @truncate(u8, selected.from);

        const x: i32 = @truncate(u8, selected.to >> 16);
        const y: i32 = @truncate(u8, selected.to >> 8);
        const z: i32 = @truncate(u8, selected.to);

        const dx = @divTrunc(x - r, self.gradient);
        const gy = @divTrunc(y - g, self.gradient);
        const bz = @divTrunc(z - b, self.gradient);

        while (i < self.gradient) : (i += 1) {
            const red = r + dx * i;
            const green = g + gy * i;
            const blue = b + bz * i;
            const rgb = @bitCast(u24, @truncate(i24, red << 16 | (green << 8) | (blue & 0xff)));
            try writer.print("#{x:0>6};{d}:", .{ rgb, 1.0 / @intToFloat(f64, self.gradient) });
        }
    }

## Interpreter main

    lang: zig esc: [[]] file: lib/Interpreter.zig
    ---------------------------------------------

    const std = @import("std");
    const lib = @import("lib.zig");
    const meta = std.meta;
    const testing = std.testing;

    const Linker = lib.Linker;
    const Parser = lib.Parser;
    const Instruction = lib.Instruction;
    const HashMap = std.AutoArrayHashMapUnmanaged;
    const Allocator = std.mem.Allocator;
    const Interpreter = @This();

    linker: Linker = .{},
    module: u16 = 1,
    ip: u32 = 0,
    stack: Stack = .{},
    indent: u16 = 0,
    should_indent: bool = false,
    last_is_newline: bool = true,

    const Stack = HashMap(u32, StackFrame);

    const StackFrame = struct {
        module: u16,
        ip: u32,
        indent: u16,
    };

    const log = std.log.scoped(.vm);

    pub fn step(vm: *Interpreter, gpa: Allocator, comptime T: type, eval: T) !bool {
        const object = vm.linker.objects.items[vm.module - 1];
        const opcode = object.program.items(.opcode);
        const data = object.program.items(.data);
        const index = vm.ip;

        vm.ip += 1;

        switch (opcode[index]) {
            .ret => return try vm.execRet(T, data[index].ret, eval),
            .jmp => try vm.execJmp(T, data[index].jmp, eval),
            .call => try vm.execCall(T, data[index].call, gpa, eval),
            .shell => vm.execShell(T, data[index].shell, object.text, eval),
            .write => try vm.execWrite(T, data[index].write, object.text, eval),
        }

        return true;
    }

    [[interpreter step]]

    pub fn deinit(vm: *Interpreter, gpa: Allocator) void {
        vm.linker.deinit(gpa);
        vm.stack.deinit(gpa);
    }

    fn Child(comptime T: type) type {
        switch (@typeInfo(T)) {
            .Pointer => |info| return info.child,
            else => return T,
        }
    }

    pub fn call(vm: *Interpreter, gpa: Allocator, symbol: []const u8, comptime T: type, eval: T) !void {
        if (vm.linker.procedures.get(symbol)) |sym| {
            vm.ip = sym.entry;
            vm.module = sym.module;
            vm.indent = 0;
            log.debug("calling {s} address {x:0>8} module {d}", .{ symbol, vm.ip, vm.module });
            while (try vm.step(gpa, T, eval)) {}
        } else return error.@"Unknown procedure";
    }

    pub fn callFile(vm: *Interpreter, gpa: Allocator, symbol: []const u8, comptime T: type, eval: T) !void {
        if (vm.linker.files.get(symbol)) |sym| {
            vm.ip = sym.entry;
            vm.module = sym.module;
            vm.indent = 0;
            log.debug("calling {s} address {x:0>8} module {d}", .{ symbol, vm.ip, vm.module });
            while (try vm.step(gpa, T, eval)) {}
        } else return error.@"Unknown procedure";
    }

    [[interpreter tests]]

# Linker

    lang: zig esc: [[]] file: lib/Linker.zig
    ----------------------------------------

    const std = @import("std");
    const lib = @import("lib.zig");
    const testing = std.testing;
    const assert = std.debug.assert;

    const Parser = lib.Parser;
    const Instruction = lib.Instruction;
    const ArrayList = std.ArrayListUnmanaged;
    const Allocator = std.mem.Allocator;
    const StringMap = std.StringArrayHashMapUnmanaged;
    const Tokenizer = lib.Tokenizer;
    const Linker = @This();

    objects: Object.List = .{},
    generation: u16 = 1,
    procedures: ProcedureMap = .{},
    files: FileMap = .{},

    const ProcedureMap = StringMap(Procedure);
    const FileMap = StringMap(Procedure);
    const Procedure = struct {
        entry: u32,
        module: u16,
        location: Tokenizer.Location,
    };

    const log = std.log.scoped(.linker);

    pub fn deinit(l: *Linker, gpa: Allocator) void {
        for (l.objects.items) |*obj| obj.deinit(gpa);
        l.objects.deinit(gpa);
        l.procedures.deinit(gpa);
        l.files.deinit(gpa);
        l.generation = undefined;
    }

    pub const Object = struct {
        name: []const u8,
        text: []const u8,
        program: Instruction.List = .{},
        symbols: SymbolMap = .{},
        adjacent: AdjacentMap = .{},
        files: Object.FileMap = .{},

        pub const List = ArrayList(Object);
        pub const SymbolMap = StringMap(SymbolList);
        pub const FileMap = StringMap(File);
        pub const SymbolList = ArrayList(u32);
        pub const AdjacentMap = StringMap(Adjacent);

        pub const File = struct {
            entry: u32,
            location: Tokenizer.Location,
        };

        pub const Adjacent = struct {
            entry: u32,
            exit: u32,
            location: Tokenizer.Location,
        };

        pub fn deinit(self: *Object, gpa: Allocator) void {
            self.program.deinit(gpa);

            for (self.symbols.values()) |*entry| entry.deinit(gpa);
            self.symbols.deinit(gpa);
            self.adjacent.deinit(gpa);
            self.files.deinit(gpa);
        }
    };

    [[linker merge adjacent blocks method]]

    [[linker build procedure table method]]

    [[linker update procedure calls method]]

    [[linker build file table method]]

    [[linker link method]]

### Merge adjacent blocks

TODO: short-circuit on non local module end

    lang: zig esc: none tag: #linker merge adjacent blocks method
    -------------------------------------------------------------

    fn mergeAdjacent(l: *Linker) void {
        for (l.objects.items) |*obj, module| {
            log.debug("processing module {d}", .{module + 1});
            const values = obj.adjacent.values();
            for (obj.adjacent.keys()) |key, i| {
                const opcodes = obj.program.items(.opcode);
                const data = obj.program.items(.data);
                const exit = values[i].exit;
                log.debug("opcode {}", .{opcodes[exit]});

                switch (opcodes[exit]) {
                    .ret, .jmp => {
                        if (opcodes[exit] == .jmp and data[exit].jmp.generation == l.generation) continue;
                        var last_adj = values[i];
                        var last_obj = obj;

                        for (l.objects.items[module + 1 ..]) |*next, offset| {
                            if (next.adjacent.get(key)) |current| {
                                const op = last_obj.program.items(.opcode)[last_adj.exit];
                                assert(op == .jmp or op == .ret);

                                const destination = @intCast(u16, module + offset) + 2;
                                log.debug("updating jump location to address 0x{x:0>8} in module {d}", .{
                                    current.entry,
                                    destination,
                                });

                                last_obj.program.items(.opcode)[last_adj.exit] = .jmp;
                                last_obj.program.items(.data)[last_adj.exit] = .{ .jmp = .{
                                    .generation = l.generation,
                                    .address = current.entry,
                                    .module = destination,
                                } };
                                last_adj = current;
                                last_obj = next;
                            }
                        }
                    },

                    else => unreachable,
                }
            }
        }
    }

    test "merge" {
        var obj_a = try Parser.parse(testing.allocator, "",
            \\
            \\
            \\    lang: zig esc: none tag: #a
            \\    ---------------------------
            \\
            \\    abc
            \\
            \\end
            \\
            \\    lang: zig esc: none tag: #b
            \\    ---------------------------
            \\
            \\    abc
            \\
            \\end
        );

        var obj_b = try Parser.parse(testing.allocator, "",
            \\
            \\
            \\    lang: zig esc: none tag: #a
            \\    ---------------------------
            \\
            \\    abc
            \\
            \\end
        );

        var obj_c = try Parser.parse(testing.allocator, "",
            \\
            \\
            \\    lang: zig esc: none tag: #b
            \\    ---------------------------
            \\
            \\    abc
            \\
            \\end
        );

        var l: Linker = .{};
        defer l.deinit(testing.allocator);

        try l.objects.appendSlice(testing.allocator, &.{
            obj_a,
            obj_b,
            obj_c,
        });

        l.mergeAdjacent();

        try testing.expectEqualSlices(Instruction.Opcode, &.{ .write, .jmp, .write, .jmp }, obj_a.program.items(.opcode));

        try testing.expectEqual(
            Instruction.Data.Jmp{
                .module = 2,
                .address = 0,
                .generation = 1,
            },
            obj_a.program.items(.data)[1].jmp,
        );

        try testing.expectEqual(
            Instruction.Data.Jmp{
                .module = 3,
                .address = 0,
                .generation = 1,
            },
            obj_a.program.items(.data)[3].jmp,
        );
    }

### Register procedures

    lang: zig esc: none tag: #linker build procedure table method
    -------------------------------------------------------------

    fn buildProcedureTable(l: *Linker, gpa: Allocator) !void {
        log.debug("building procedure table", .{});
        for (l.objects.items) |obj, module| {
            log.debug("processing module {d} with {d} procedures", .{ module + 1, obj.adjacent.keys().len });
            for (obj.adjacent.keys()) |key, i| {
                const entry = try l.procedures.getOrPut(gpa, key);
                if (!entry.found_existing) {
                    const adjacent = obj.adjacent.values()[i];
                    log.debug("registering new procedure '{s}' address {x:0>8} module {d}", .{
                        key,
                        adjacent.entry,
                        module + 1,
                    });

                    entry.value_ptr.* = .{
                        .module = @intCast(u16, module) + 1,
                        .entry = @intCast(u32, adjacent.entry),
                        .location = adjacent.location,
                    };
                }
            }
        }
        log.debug("registered {d} procedures", .{l.procedures.count()});
    }

### Update procedure calls

    lang: zig esc: none tag: #linker update procedure calls method
    --------------------------------------------------------------

    fn updateProcedureCalls(l: *Linker) void {
        log.debug("updating procedure calls", .{});
        for (l.procedures.keys()) |key, i| {
            const proc = l.procedures.values()[i];
            for (l.objects.items) |*obj| if (obj.symbols.get(key)) |sym| {
                log.debug("updating locations {any}", .{sym.items});
                for (sym.items) |location| {
                    assert(obj.program.items(.opcode)[location] == .call);
                    const call = &obj.program.items(.data)[location].call;
                    call.address = proc.entry;
                    call.module = proc.module;
                }
            };
        }
    }

### Check for file conflicts and build a file table

    lang: zig esc: none tag: #linker build file table method
    --------------------------------------------------------

    fn buildFileTable(l: *Linker, gpa: Allocator) !void {
        for (l.objects.items) |obj, module| {
            for (obj.files.keys()) |key, i| {
                const file = try l.files.getOrPut(gpa, key);
                const record = obj.files.values()[i];
                if (file.found_existing) return error.@"Multiple files with the same name";
                file.value_ptr.module = @intCast(u16, module) + 1;
                file.value_ptr.entry = record.entry;
                file.value_ptr.location = record.location;
            }
        }
    }

### Link

    lang: zig esc: none tag: #linker link method
    --------------------------------------------

    pub fn link(l: *Linker, gpa: Allocator) !void {
        l.procedures.clearRetainingCapacity();
        l.files.clearRetainingCapacity();

        try l.buildProcedureTable(gpa);
        try l.buildFileTable(gpa);

        l.mergeAdjacent();
        l.updateProcedureCalls();

        var failure = false;
        for (l.objects.items) |obj| {
            for (obj.symbols.keys()) |key| {
                if (!l.procedures.contains(key)) {
                    failure = true;
                    log.err("unknown symbol '{s}'", .{key});
                }
            }
        }

        if (failure) return error.@"Unknown symbol";
    }

    test "call" {
        var obj = try Parser.parse(testing.allocator, "",
            \\
            \\
            \\    lang: zig esc: none tag: #a
            \\    ---------------------------
            \\
            \\    abc
            \\
            \\end
            \\
            \\    lang: zig esc: [[]] tag: #b
            \\    ---------------------------
            \\
            \\    [[a]]
            \\
            \\end
        );

        var l: Linker = .{};
        defer l.deinit(testing.allocator);

        try l.objects.append(testing.allocator, obj);
        try l.link(testing.allocator);

        try testing.expectEqualSlices(
            Instruction.Opcode,
            &.{ .write, .ret, .call, .ret },
            obj.program.items(.opcode),
        );

        try testing.expectEqual(
            Instruction.Data.Call{
                .address = 0,
                .module = 1,
                .indent = 0,
            },
            obj.program.items(.data)[2].call,
        );
    }

# Parser

    lang: zig esc: [[]] file: lib/Parser.zig
    ----------------------------------------

    const std = @import("std");
    const lib = @import("lib.zig");
    const mem = std.mem;
    const testing = std.testing;
    const assert = std.debug.assert;

    const Tokenizer = lib.Tokenizer;
    const Linker = lib.Linker;
    const Allocator = std.mem.Allocator;
    const Instruction = lib.Instruction;
    const Location = Tokenizer.Location;
    const Parser = @This();

    it: Tokenizer,
    program: Instruction.List = .{},
    symbols: Linker.Object.SymbolMap = .{},
    adjacent: Linker.Object.AdjacentMap = .{},
    files: Linker.Object.FileMap = .{},
    location: Location = .{},

    const Token = Tokenizer.Token;
    const log = std.log.scoped(.parser);

    pub fn deinit(p: *Parser, gpa: Allocator) void {
        p.program.deinit(gpa);
        for (p.symbols.values()) |*entry| entry.deinit(gpa);
        p.symbols.deinit(gpa);
        p.adjacent.deinit(gpa);
        p.files.deinit(gpa);
        p.* = undefined;
    }

    [[zangle parser primitives]]
    [[zangle parser]]

## Token

    lang: zig esc: none tag: #zangle tokenizer token
    ------------------------------------------------

    pub const Token = struct {
        tag: Tag,
        start: usize,
        end: usize,

        pub const Tag = enum(u8) {
            eof,

            nl = '\n',
            space = ' ',

            word,
            line = '-',
            hash = '#',
            pipe = '|',
            colon = ':',

            l_angle = '<',
            l_brace = '{',
            l_bracket = '[',
            l_paren = '(',

            r_angle = '>',
            r_brace = '}',
            r_bracket = ']',
            r_paren = ')',

            unknown,
        };

        pub fn slice(t: Token, bytes: []const u8) []const u8 {
            return bytes[t.start..t.end];
        }

        pub fn len(t: Token) usize {
            return t.end - t.start;
        }
    };

## Tokenizer

![Zangle tokenizer state transition graph](out/tokenizer-state-transitions.png)

\hidden{

    lang: dot esc: {{}} file: graphs/tokenizer-state-transitions.dot
    ----------------------------------------------------------------

    digraph G {
        node [shape = doublecircle] start;
        node [shape = rectangle];
        rankdir = LR;
        layout = "dot";

        {{tokenizer state transition}}
    }

}

<!-- -->

    lang: zig esc: [[]] file: lib/Tokenizer.zig
    -------------------------------------------

    const std = @import("std");
    const mem = std.mem;
    const testing = std.testing;
    const assert = std.debug.assert;

    const Tokenizer = @This();

    bytes: []const u8,
    index: usize = 0,

    pub const Location = struct {
        line: usize = 1,
        column: usize = 1,
    };

    const log = std.log.scoped(.tokenizer);

    [[zangle tokenizer token]]

    pub fn locationFrom(self: Tokenizer, from: Location) Location {
        assert(from.line != 0);
        assert(from.column != 0);

        var loc = from;
        const start = from.line * from.column - 1;

        for (self.bytes[start..self.index]) |byte| {
            if (byte == '\n') {
                loc.line += 1;
                loc.column = 1;
            } else {
                loc.column += 1;
            }
        }

        return loc;
    }

    pub fn next(self: *Tokenizer) Token {
        var token: Token = .{
            .tag = .eof,
            .start = self.index,
            .end = undefined,
        };

        defer log.debug("{s: >10} {d: >3} | {s}", .{
            @tagName(token.tag),
            token.len(),
            token.slice(self.bytes),
        });

        const State = enum { start, trivial, unknown, word };
        var state: State = .start;
        var trivial: u8 = 0;

        while (self.index < self.bytes.len) : (self.index += 1) {
            const c = self.bytes[self.index];
            switch (state) {
                .start => switch (c) {
                    [[zangle tokenizer start transitions]]
                },

                [[zangle tokenizer state transitions]]
            }
        }

        token.end = self.index;
        return token;
    }

    [[zangle tokenizer tests]]

#### Trivial

\hidden{

    lang: dot esc: none tag: #tokenizer state transition
    ----------------------------------------------------

    trivial -> trivial [label = "same byte"];
    trivial -> end;

}

    lang: zig esc: none tag: #zangle tokenizer state transitions
    ------------------------------------------------------------

    .trivial => if (c != trivial) break,

#### Whitespace

\hidden{

    lang: dot esc: none tag: #tokenizer state transition
    ----------------------------------------------------

    start -> trivial [label = "space, nl"];

}

Whitespace of the same type is consumed as a single token.

    lang: zig esc: none tag: #zangle tokenizer start transitions
    ------------------------------------------------------------

    ' ', '\n' => {
        token.tag = @intToEnum(Token.Tag, c);
        trivial = c;
        state = .trivial;
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer tests
    ------------------------------------------------

    test "tokenize whitespace" {
        try testTokenize("\n", &.{.nl});
        try testTokenize(" ", &.{.space});
        try testTokenize("\n\n\n\n\n", &.{.nl});
        try testTokenize("\n\n     \n\n\n", &.{ .nl, .space, .nl });
    }

#### Header

\hidden{

    lang: dot esc: none tag: #tokenizer state transition
    ----------------------------------------------------

    start -> trivial [label = "line"];
    start -> word [label = "a...z"];
    start -> end [label = "hash, colon"];

}

    lang: zig esc: none tag: #zangle tokenizer start transitions
    ------------------------------------------------------------

    '-' => {
        token.tag = .line;
        trivial = '-';
        state = .trivial;
    },

    'a'...'z' => {
        token.tag = .word;
        state = .word;
    },

    '#', ':' => {
        token.tag = @intToEnum(Token.Tag, c);
        self.index += 1;
        break;
    },

\hidden{

    lang: dot esc: none tag: #tokenizer state transition
    ----------------------------------------------------

    word -> word [label = "a...z, A...Z, #, +, -, \\, _"];
    word -> end;

}

    lang: zig esc: none tag: #zangle tokenizer state transitions
    ------------------------------------------------------------

    .word => switch (c) {
        'a'...'z', 'A'...'Z', '#', '+', '-', '\'', '_' => {},
        else => break,
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer tests
    ------------------------------------------------

    test "tokenize header" {
        try testTokenize("-", &.{.line});
        try testTokenize("#", &.{.hash});
        try testTokenize(":", &.{.colon});
        try testTokenize("-----------------", &.{.line});
        try testTokenize("###", &.{ .hash, .hash, .hash });
        try testTokenize(":::", &.{ .colon, .colon, .colon });
    }

#### Include

\hidden{

    lang: dot esc: none tag: #tokenizer state transition
    ----------------------------------------------------

    start -> trivial [label = "<, {, [, (, ), ], }, >"];

}

    lang: zig esc: none tag: #zangle tokenizer start transitions
    ------------------------------------------------------------

    '<', '{', '[', '(', ')', ']', '}', '>' => {
        token.tag = @intToEnum(Token.Tag, c);
        trivial = c;
        state = .trivial;
    },

\hidden{

    lang: dot esc: none tag: #tokenizer state transition
    ----------------------------------------------------

    start -> end [label = "pipe"];

}

    lang: zig esc: none tag: #zangle tokenizer start transitions
    ------------------------------------------------------------

    '|' => {
        token.tag = .pipe;
        self.index += 1;
        break;
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer tests
    ------------------------------------------------

    test "tokenize include" {
        try testTokenize("|", &.{.pipe});
        try testTokenize("|||", &.{ .pipe, .pipe, .pipe });
    }

#### Unknown

\hidden{

    lang: dot esc: none tag: #tokenizer state transition
    ----------------------------------------------------

    start -> unknown [label = "unknown"];

}

    lang: zig esc: none tag: #zangle tokenizer start transitions
    ------------------------------------------------------------

    else => {
        token.tag = .unknown;
        state = .unknown;
    },

\hidden{

    lang: dot esc: none tag: #tokenizer state transition
    ----------------------------------------------------

    unknown -> unknown;
    unknown -> end [label = "nl, <, {, [, (, ), ], }, >, colon, pipe"];

}

    lang: zig esc: none tag: #zangle tokenizer state transitions
    ------------------------------------------------------------

    .unknown => if (mem.indexOfScalar(u8, "\n <{[()]}>:|", c)) |_| {
        break;
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer tests
    ------------------------------------------------

    test "tokenize unknown" {
        try testTokenize("/file.example/path/../__", &.{.unknown});
    }

## Header

Each code block starts with a header specifying the language used, delimiters
for code block imports, and either a file in which the content should be
written to or a tag which may be referenced with import statements.

TODO: record statistisc on the number of tag occurences so it's possible to
display `Tag: example tag (5/16)`.

TODO: link same tags together so they form a chain and a loop back to the
start at the end. This allows the user to click through to the next block.

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

    const Header = struct {
        language: []const u8,
        delimiter: ?[]const u8,
        resource: Slice,
        type: Type,

        pub const Slice = struct {
            start: u32,
            len: u16,

            pub fn slice(self: Slice, text: []const u8) []const u8 {
                return text[self.start .. self.start + self.len];
            }
        };

        pub const Type = enum { file, tag };
    };

    const ParseHeaderError = error{
        @"Expected a space between 'lang:' and the language name",
        @"Expected a space after the language name",
        @"Expected a space between 'esc:' and the delimiter specification",
        @"Expected open delimiter",
        @"Expected closing delimiter",
        @"Expected matching closing angle bracket '>'",
        @"Expected matching closing brace '}'",
        @"Expected matching closing bracket ']'",
        @"Expected matching closing paren ')'",
        @"Expected opening and closing delimiter lengths to match",
        @"Expected a space after delimiter specification",
        @"Expected 'tag:' or 'file:' following delimiter specification",
        @"Expected a space after 'file:'",
        @"Expected a space after 'tag:'",
        @"Expected a newline after the header",
        @"Expected the dividing line to be indented by 4 spaces",
        @"Expected a dividing line of '-' of the same length as the header",
        @"Expected the division line to be of the same length as the header",
        @"Expected at least one blank line after the division line",
        @"Expected there to be only one space but more were given",

        @"Missing language specification",
        @"Missing ':' after 'lang'",
        @"Missing language name",
        @"Missing 'esc:' delimiter specification",
        @"Missing ':' after 'esc'",
        @"Missing ':' after 'file'",
        @"Missing ':' after 'tag'",
        @"Missing '#' after 'tag: '",
        @"Missing file name",
        @"Missing tag name",

        @"Invalid delimiter, expected one of '<', '{', '[', '('",
        @"Invalid delimiter, expected one of '>', '}', ']', ')'",
        @"Invalid option given, expected 'tag:' or 'file:'",
        @"Invalid file path, parent directory references '../' and '..\\' are not allowed within output paths",
        @"Invalid file path, current directory references './' and '.\\' are not allowed within output paths",
    };

    fn parseHeaderLine(p: *Parser) ParseHeaderError!Header {
        var header: Header = undefined;

        const header_start = p.it.index;
        p.match(.word, "lang") orelse return error.@"Missing language specification";
        p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'lang'";

        if (p.eat(.space, @src())) |space| {
            if (space.len != 1) return error.@"Expected there to be only one space but more were given";
        } else {
            return error.@"Expected a space between 'lang:' and the language name";
        }

        header.language = p.eat(.word, @src()) orelse return error.@"Missing language name";
        p.expect(.space, @src()) orelse return error.@"Expected a space after the language name";
        p.match(.word, "esc") orelse return error.@"Missing 'esc:' delimiter specification";
        p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'esc'";

        if (p.eat(.space, @src())) |space| {
            if (space.len != 1) return error.@"Expected there to be only one space but more were given";
        } else {
            return error.@"Expected a space between 'esc:' and the delimiter specification";
        }

        if (p.match(.word, "none") == null) {
            const start = p.it.index;
            const open = p.next() orelse return error.@"Expected open delimiter";

            switch (open.tag) {
                .l_angle, .l_brace, .l_bracket, .l_paren => {},
                else => return error.@"Invalid delimiter, expected one of '<', '{', '[', '('",
            }

            const closed = p.next() orelse return error.@"Expected closing delimiter";
            switch (closed.tag) {
                .r_angle, .r_brace, .r_bracket, .r_paren => {},
                else => return error.@"Invalid delimiter, expected one of '>', '}', ']', ')'",
            }

            if (open.tag == .l_angle and closed.tag != .r_angle) {
                return error.@"Expected matching closing angle bracket '>'";
            } else if (open.tag == .l_brace and closed.tag != .r_brace) {
                return error.@"Expected matching closing brace '}'";
            } else if (open.tag == .l_bracket and closed.tag != .r_bracket) {
                return error.@"Expected matching closing bracket ']'";
            } else if (open.tag == .l_paren and closed.tag != .r_paren) {
                return error.@"Expected matching closing paren ')'";
            }

            if (open.len() != closed.len()) {
                return error.@"Expected opening and closing delimiter lengths to match";
            }

            header.delimiter = p.slice(start, p.it.index);
        } else {
            header.delimiter = null;
        }

        if (p.eat(.space, @src())) |space| {
            if (space.len != 1) return error.@"Expected there to be only one space but more were given";
        } else {
            return error.@"Expected a space after delimiter specification";
        }

        var start: usize = undefined;
        const tag = p.eat(.word, @src()) orelse {
            return error.@"Expected 'tag:' or 'file:' following delimiter specification";
        };

        if (mem.eql(u8, tag, "file")) {
            p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'file'";

            if (p.eat(.space, @src())) |space| {
                if (space.len != 1) return error.@"Expected there to be only one space but more were given";
            } else return error.@"Expected a space after 'file:'";

            header.type = .file;
            start = p.it.index;
        } else if (mem.eql(u8, tag, "tag")) {
            p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'tag'";

            if (p.eat(.space, @src())) |space| {
                if (space.len != 1) return error.@"Expected there to be only one space but more were given";
            } else return error.@"Expected a space after 'tag:'";

            p.expect(.hash, @src()) orelse return error.@"Missing '#' after 'tag: '";
            header.type = .tag;
            start = p.it.index;
        } else {
            return error.@"Invalid option given, expected 'tag:' or 'file:'";
        }

        const nl = p.scan(.nl) orelse {
            return error.@"Expected a newline after the header";
        };

        header.resource = .{
            .start = @intCast(u32, start),
            .len = @intCast(u16, nl.start - start),
        };

File paths may specify `../` and `./` which are valid paths but the former
allows reaching outside of the project root while the other is confusing as
it always references the current directory. Since zangle shouldn't be able
to reach outside of the directory unless explicit permission is given via a
command-line flag and the other makes little sense, both options are treated
as parser errors.

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

        const resource = header.resource.slice(p.it.bytes);

        if (header.type == .file) for (&[_][]const u8{ "../", "..\\" }) |invalid| {
            if (mem.indexOf(u8, resource, invalid)) |index| {
                if (index == 0 or resource[index - 1] != '.') {
                    return error.@"Invalid file path, parent directory references '../' and '..\\' are not allowed within output paths";
                }
            }
        };

        if (header.type == .file) for (&[_][]const u8{ "./", ".\\" }) |invalid| {
            if (mem.indexOf(u8, resource, invalid)) |index| {
                if (index == 0 or resource[index - 1] != '.') {
                    return error.@"Invalid file path, current directory references './' and '.\\' are not allowed within output paths";
                }
            }
        };

<!-- -->

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

        if (header.resource.len == 0) {
            switch (header.type) {
                .file => return error.@"Missing file name",
                .tag => return error.@"Missing tag name",
            }
        }

        const len = (p.it.index - 1) - header_start;

        if ((p.eat(.space, @src()) orelse "").len != 4) {
            return error.@"Expected the dividing line to be indented by 4 spaces";
        }

        const line = p.eat(.line, @src()) orelse {
            return error.@"Expected a dividing line of '-' of the same length as the header";
        };

        if (line.len != len) {
            log.debug("header {d} line {d}", .{ len, line.len });
            return error.@"Expected the division line to be of the same length as the header";
        }

        if ((p.eat(.nl, @src()) orelse "").len < 2) {
            return error.@"Expected at least one blank line after the division line";
        }

        return header;
    }

## Body

TODO: link tags to their definition

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

    fn parseBody(p: *Parser, gpa: Allocator, header: Header) !void {
        log.debug("begin parsing body", .{});
        defer log.debug("end parsing body", .{});

        const entry_point = @intCast(u32, p.program.len);
        const location = p.it.locationFrom(p.location);
        p.location = location; // avoid RLS

        var nl: usize = 0;
        loop: while (p.eat(.space, @src())) |space| {
            if (space.len < 4) break;
            nl = 0;

            var sol = p.it.index - (space.len - 4);
            while (true) {
                const token = p.it.next();
                switch (token.tag) {
                    .eof => {
                        try p.emitWrite(gpa, .{
                            .start = @intCast(u32, sol),
                            .len = @intCast(u16, token.start - sol),
                            .nl = 0,
                        });
                        break :loop;
                    },

                    .nl => {
                        nl = token.len();

                        try p.emitWrite(gpa, .{
                            .start = @intCast(u32, sol),
                            .len = @intCast(u16, token.start - sol),
                            .nl = @intCast(u16, nl),
                        });
                        break;
                    },

                    .l_angle,
                    .l_brace,
                    .l_bracket,
                    .l_paren,
                    => if (header.delimiter) |delim| {
                        if (delim[0] != @enumToInt(token.tag)) {
                            log.debug("dilimiter doesn't match, skipping", .{});
                            continue;
                        }

                        if (delim.len != token.len() * 2) {
                            log.debug("dilimiter length doesn't match, skipping", .{});
                            continue;
                        }

                        if (token.start - sol > 0) {
                            try p.emitWrite(gpa, .{
                                .start = @intCast(u32, sol),
                                .len = @intCast(u16, token.start - sol),
                                .nl = 0,
                            });
                        }

                        try p.parseDelimiter(gpa, delim, token.start - sol);
                        sol = p.it.index;
                    },

                    else => {},
                }
            }
        }

        const len = p.program.len;
        if (len != 0) {
            const item = &p.program.items(.data)[len - 1].write;
            item.nl = 0;
            if (item.len == 0) p.program.len -= 1;
        }

        if (nl < 2 and p.it.index < p.it.bytes.len) {
            return error.@"Expected a blank line after the end of the code block";
        }

        switch (header.type) {
            .tag => {
                const adj = try p.adjacent.getOrPut(gpa, header.resource.slice(p.it.bytes));
                if (adj.found_existing) {
                    try p.writeJmp(adj.value_ptr.exit, .{
                        .address = entry_point,
                        .module = 0,
                    });
                } else {
                    adj.value_ptr.entry = entry_point;
                    adj.value_ptr.location = location;
                }

                adj.value_ptr.exit = @intCast(u32, p.program.len);
            },

            .file => {
                const file = try p.files.getOrPut(gpa, header.resource.slice(p.it.bytes));
                if (file.found_existing) return error.@"Multiple file outputs with the same name";
                file.value_ptr.* = .{
                    .entry = entry_point,
                    .location = location,
                };
            },
        }

        try p.emitRet(gpa, .{
            .start = header.resource.start,
            .len = header.resource.len,
        });
    }

#### Delimiters

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

    fn parseDelimiter(
        p: *Parser,
        gpa: Allocator,
        delim: []const u8,
        indent: usize,
    ) !void {
        log.debug("parsing call", .{});

        var pipe = false;
        var colon = false;
        var reached_end = false;

        const tag = blk: {
            const start = p.it.index;
            while (p.next()) |sub| switch (sub.tag) {
                .nl => return error.@"Unexpected newline",
                .pipe => {
                    pipe = true;
                    break :blk p.it.bytes[start..sub.start];
                },
                .colon => {
                    colon = true;
                    break :blk p.it.bytes[start..sub.start];
                },

                .r_angle,
                .r_brace,
                .r_bracket,
                .r_paren,
                => if (@enumToInt(sub.tag) == delim[delim.len - 1]) {
                    if (delim.len != sub.len() * 2) {
                        return error.@"Expected a closing delimiter of equal length";
                    }
                    reached_end = true;
                    break :blk p.it.bytes[start..sub.start];
                },

                else => {},
            };

            return error.@"Unexpected end of file";
        };


Type casts must be given if the imported code block has a different type
than the target code block.

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

        if (colon) {
            const ty = p.eat(.word, @src()) orelse return error.@"Missing 'from' following ':'";
            if (!mem.eql(u8, ty, "from")) return error.@"Unknown type operation";
            p.expect(.l_paren, @src()) orelse return error.@"Expected '(' following 'from'";
            p.expect(.word, @src()) orelse return error.@"Expected type name";
            p.expect(.r_paren, @src()) orelse return error.@"Expected ')' following type name";
        }

Pipes pass code blocks through external programs.

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

        if (pipe or p.eat(.pipe, @src()) != null) {
            const index = @intCast(u32, p.it.index);
            const shell = p.eat(.word, @src()) orelse {
                return error.@"Missing command following '|'";
            };

            if (shell.len > 255) return error.@"Shell command name too long";
            try p.emitShell(gpa, .{
                .command = index,
                .module = 0xffff,
                .len = @intCast(u8, shell.len),
                .pad = 0,
            });
        }

        try p.emitCall(gpa, tag, .{
            .address = undefined,
            .module = undefined,
            .indent = @intCast(u16, indent),
        });

        if (!reached_end) {
            const last = p.next() orelse return error.@"Expected closing delimiter";

            if (last.len() * 2 != delim.len) {
                return error.@"Expected closing delimiter length to match";
            }

            if (@enumToInt(last.tag) != delim[delim.len - 1]) {
                return error.@"Invalid closing delimiter";
            }
        }
    }

    test "parse body" {
        const text =
            \\    <<a b c:from(t)|f>>
            \\    [[a b c | : a}}
            \\    <<b|k>>
            \\    <<b:from(k)>>
            \\    <<<|:>>
            \\    <|:>
            \\
            \\text
        ;

        var p: Parser = .{ .it = .{ .bytes = text } };
        defer p.deinit(testing.allocator);
        try p.parseBody(testing.allocator, .{
            .language = "",
            .delimiter = "<<>>",
            .resource = .{ .start = 0, .len = 0 },
            .type = .tag,
        });
    }

    test "compile single tag" {
        const text =
            \\    <<a b c>>
            \\    <<. . .:from(zig)>>
            \\    <<1 2 3|com>>
            \\
            \\end
        ;

        var p: Parser = .{ .it = .{ .bytes = text } };
        defer p.deinit(testing.allocator);
        try p.parseBody(testing.allocator, .{
            .language = "",
            .delimiter = "<<>>",
            .resource = .{ .start = 0, .len = 0 },
            .type = .tag,
        });

        try testing.expect(p.symbols.contains("a b c"));
        try testing.expect(p.symbols.contains("1 2 3"));
        try testing.expect(p.symbols.contains(". . ."));
    }

    pub fn parse(gpa: Allocator, name: []const u8, text: []const u8) !Linker.Object {
        var p: Parser = .{ .it = .{ .bytes = text } };
        errdefer p.deinit(gpa);

        while (try p.step(gpa)) {}

        return Linker.Object{
            .name = name,
            .text = text,
            .program = p.program,
            .symbols = p.symbols,
            .adjacent = p.adjacent,
            .files = p.files,
        };
    }

    pub fn object(p: *Parser, name: []const u8) Linker.Object {
        return Linker.Object{
            .name = name,
            .text = p.it.bytes,
            .program = p.program,
            .symbols = p.symbols,
            .adjacent = p.adjacent,
            .files = p.files,
        };
    }

    pub fn step(p: *Parser, gpa: Allocator) !bool {
        while (p.next()) |token| if (token.tag == .nl and token.len() >= 2) {
            const space = p.eat(.space, @src()) orelse continue;
            if (space.len != 4) continue;

            if (p.parseHeaderLine()) |header| {
                try p.parseBody(gpa, header);
            } else |e| switch (e) {
                error.@"Missing language specification" => {
                    log.debug("begin indented block", .{});
                    defer log.debug("end indented block", .{});

                    while (p.scan(.nl)) |nl| if (nl.len() >= 2) {
                        const tmp = p.next() orelse return false;
                        if (tmp.tag != .space) return true;
                        if (tmp.len() < 4) return true;
                    };
                },

                else => |err| return err,
            }
        };

        return false;
    }

# Appendix. Parser tests

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

    test "parse header line" {
        const complete_header = "lang: zig esc: {{}} tag: #hash\n    ------------------------------\n\n";
        const common: Header = .{
            .language = "zig",
            .delimiter = "{{}}",
            .resource = .{
                .start = @intCast(u32, mem.indexOf(u8, complete_header, "hash").?),
                .len = 4,
            },
            .type = .tag,
        };

        try testing.expectError(
            error.@"Expected a space between 'lang:' and the language name",
            testParseHeader("lang:zig", common),
        );

        try testing.expectError(
            error.@"Missing 'esc:' delimiter specification",
            testParseHeader("lang: zig ", common),
        );

        try testing.expectError(
            error.@"Missing ':' after 'esc'",
            testParseHeader("lang: zig esc", common),
        );

        try testing.expectError(
            error.@"Expected a space between 'esc:' and the delimiter specification",
            testParseHeader("lang: zig esc:", common),
        );

        try testing.expectError(
            error.@"Expected closing delimiter",
            testParseHeader("lang: zig esc: {", common),
        );

        try testing.expectError(
            error.@"Expected matching closing angle bracket '>'",
            testParseHeader("lang: zig esc: <}", common),
        );

        try testing.expectError(
            error.@"Expected matching closing brace '}'",
            testParseHeader("lang: zig esc: {>", common),
        );

        try testing.expectError(
            error.@"Expected matching closing bracket ']'",
            testParseHeader("lang: zig esc: [>", common),
        );

        try testing.expectError(
            error.@"Expected matching closing paren ')'",
            testParseHeader("lang: zig esc: (>", common),
        );

        try testing.expectError(
            error.@"Invalid delimiter, expected one of '<', '{', '[', '('",
            testParseHeader("lang: zig esc: foo", common),
        );

        try testing.expectError(
            error.@"Invalid delimiter, expected one of '>', '}', ']', ')'",
            testParseHeader("lang: zig esc: <oo", common),
        );

        try testing.expectError(
            error.@"Expected opening and closing delimiter lengths to match",
            testParseHeader("lang: zig esc: {}}", common),
        );

        try testing.expectError(
            error.@"Expected a space after delimiter specification",
            testParseHeader("lang: zig esc: {{}}", common),
        );

        try testing.expectError(
            error.@"Expected 'tag:' or 'file:' following delimiter specification",
            testParseHeader("lang: zig esc: {{}} ", common),
        );

        try testing.expectError(
            error.@"Invalid option given, expected 'tag:' or 'file:'",
            testParseHeader("lang: zig esc: {{}} none", common),
        );

        try testing.expectError(
            error.@"Missing ':' after 'file'",
            testParseHeader("lang: zig esc: {{}} file", common),
        );

        try testing.expectError(
            error.@"Expected a space after 'file:'",
            testParseHeader("lang: zig esc: {{}} file:", common),
        );

        try testing.expectError(
            error.@"Missing file name",
            testParseHeader("lang: zig esc: {{}} file: \n", common),
        );

        try testing.expectError(
            error.@"Invalid file path, parent directory references '../' and '..\\' are not allowed within output paths",
            testParseHeader("lang: zig esc: {{}} file: ../../../../etc/foo\n", common),
        );

        try testing.expectError(
            error.@"Invalid file path, current directory references './' and '.\\' are not allowed within output paths",
            testParseHeader("lang: zig esc: {{}} file: ./foo\n", common),
        );

        try testing.expectError(
            error.@"Expected the dividing line to be indented by 4 spaces",
            testParseHeader("lang: zig esc: {{}} file: .../foo\n", common),
        );

        try testing.expectError(
            error.@"Missing ':' after 'tag'",
            testParseHeader("lang: zig esc: {{}} tag", common),
        );

        try testing.expectError(
            error.@"Expected a space after 'tag:'",
            testParseHeader("lang: zig esc: {{}} tag:", common),
        );

        try testing.expectError(
            error.@"Missing '#' after 'tag: '",
            testParseHeader("lang: zig esc: {{}} tag: ", common),
        );

        try testing.expectError(
            error.@"Expected a newline after the header",
            testParseHeader("lang: zig esc: {{}} tag: #", common),
        );

        try testing.expectError(
            error.@"Missing tag name",
            testParseHeader("lang: zig esc: {{}} tag: #\n", common),
        );

        try testing.expectError(
            error.@"Expected the dividing line to be indented by 4 spaces",
            testParseHeader("lang: zig esc: {{}} tag: #hash\n", common),
        );

        try testing.expectError(
            error.@"Expected a dividing line of '-' of the same length as the header",
            testParseHeader("lang: zig esc: {{}} tag: #hash\n    ", common),
        );

        try testing.expectError(
            error.@"Expected the division line to be of the same length as the header",
            testParseHeader("lang: zig esc: {{}} tag: #hash\n    ----------------", common),
        );

        try testing.expectError(
            error.@"Expected at least one blank line after the division line",
            testParseHeader("lang: zig esc: {{}} tag: #hash\n    ------------------------------", common),
        );

        try testing.expectError(
            error.@"Expected at least one blank line after the division line",
            testParseHeader("lang: zig esc: {{}} tag: #hash\n    ------------------------------\n", common),
        );

        try testParseHeader(complete_header, common);
    }

    fn testParseHeader(text: []const u8, expected: Header) !void {
        var p: Parser = .{ .it = .{ .bytes = text } };
        const header = try p.parseHeaderLine();

        testing.expectEqualStrings(expected.language, header.language) catch return error.@"Language is not the same";

        if (expected.delimiter != null and header.delimiter != null) {
            testing.expectEqualStrings(expected.language, header.language) catch return error.@"Delimiter is not the same";
        } else if (expected.delimiter == null and header.delimiter != null) {
            return error.@"Expected delimiter to be null";
        } else if (expected.delimiter != null and header.delimiter == null) {
            return error.@"Expected delimiter to not be null";
        }

        testing.expectEqual(expected.resource, header.resource) catch return error.@"Resource is not the same";
        testing.expectEqual(expected.type, header.type) catch return error.@"Type is not the same";
    }

    const TestCompileResult = struct {
        program: []const Instruction.Opcode,
        symbols: []const []const u8,
        exports: []const []const u8,
    };

    fn testCompile(
        text: []const u8,
        result: TestCompileResult,
    ) !void {
        var obj = try Parser.parse(testing.allocator, "", text);
        defer obj.deinit(testing.allocator);

        errdefer for (obj.program.items(.opcode)) |op| {
            log.debug("{s}", .{@tagName(op)});
        };

        try testing.expectEqualSlices(
            Instruction.Opcode,
            result.program,
            obj.program.items(.opcode),
        );

        for (result.symbols) |sym| if (!obj.symbols.contains(sym)) {
            std.log.err("Missing symbol '{s}'", .{sym});
        };
    }

    test "compile block" {
        try testCompile(
            \\begin
            \\
            \\    lang: zig esc: <<>> tag: #here
            \\    ------------------------------
            \\
            \\    <<example>>
            \\
            \\end
        , .{
            .program = &.{ .call, .ret },
            .symbols = &.{"example"},
            .exports = &.{"here"},
        });
    }

    test "compile block with jump threadding" {
        try testCompile(
            \\begin
            \\
            \\    lang: zig esc: <<>> tag: #here
            \\    ------------------------------
            \\
            \\    <<example>>
            \\
            \\then
            \\
            \\    lang: zig esc: none tag: #here
            \\    ------------------------------
            \\
            \\    more
            \\
            \\end
        , .{
            .program = &.{ .call, .jmp, .write, .ret },
            .symbols = &.{"example"},
            .exports = &.{"here"},
        });
    }

    test "compile block multiple call" {
        try testCompile(
            \\begin
            \\
            \\    lang: zig esc: <<>> tag: #here
            \\    ------------------------------
            \\
            \\    <<one>>
            \\    <<two>>
            \\    <<three>>
            \\
            \\end
        , .{
            .program = &.{ .call, .write, .call, .write, .call, .ret },
            .symbols = &.{ "one", "two", "three" },
            .exports = &.{"here"},
        });
    }

    test "compile block inline" {
        try testCompile(
            \\begin
            \\
            \\    lang: zig esc: <<>> tag: #here
            \\    ------------------------------
            \\
            \\    <<one>><<two>>
            \\
            \\end
        , .{
            .program = &.{ .call, .call, .ret },
            .symbols = &.{ "one", "two" },
            .exports = &.{"here"},
        });
    }

    test "compile block inline indent" {
        try testCompile(
            \\begin
            \\
            \\    lang: zig esc: <<>> tag: #here
            \\    ------------------------------
            \\
            \\    one<<two>>
            \\
            \\end
        , .{
            .program = &.{ .write, .call, .ret },
            .symbols = &.{"two"},
            .exports = &.{"here"},
        });
    }

    test "compile indented" {
        try testCompile(
            \\begin
            \\
            \\    normal code block
            \\
            \\end
            \\
            \\    lang: zig esc: <<>> tag: #here
            \\    ------------------------------
            \\
            \\    <<one>><<two>>
            \\
            \\end
        , .{
            .program = &.{ .call, .call, .ret },
            .symbols = &.{ "one", "two" },
            .exports = &.{"here"},
        });
    }

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer tests
    ------------------------------------------------

    fn testTokenize(text: []const u8, expected: []const Token.Tag) !void {
        var it: Tokenizer = .{ .bytes = text };

        for (expected) |tag| {
            const token = it.next();
            try testing.expectEqual(tag, token.tag);
        }

        const token = it.next();
        try testing.expectEqual(Token.Tag.eof, token.tag);
        try testing.expectEqual(text.len, token.end);
    }

# Appendix. Interpreter tests

    lang: zig esc: none tag: #interpreter tests
    -------------------------------------------

    const TestTangleOutput = struct {
        name: []const u8,
        text: []const u8,
    };

    fn testTangle(source: []const []const u8, output: []const TestTangleOutput) !void {
        var owned = true;
        var l: Linker = .{};
        defer if (owned) l.deinit(testing.allocator);

        for (source) |src| {
            const obj = try Parser.parse(testing.allocator, "", src);
            try l.objects.append(testing.allocator, obj);
        }

        try l.link(testing.allocator);

        var vm: Interpreter = .{ .linker = l };
        defer vm.deinit(testing.allocator);
        owned = false;

        errdefer for (l.objects.items) |obj, i| {
            log.debug("module {d}", .{i + 1});
            for (obj.program.items(.opcode)) |op| {
                log.debug("{}", .{op});
            }
        };

        for (output) |out| {
            log.debug("evaluating {s}", .{out.name});
            var buffer: [4096]u8 = undefined;
            var context: Test = .{ .stream = .{ .buffer = &buffer, .pos = 0 } };
            try vm.call(testing.allocator, out.name, *Test, &context);
            try context.expect(out.text);
        }
    }

    test "run simple no calls" {
        try testTangle(&.{
            \\begin
            \\
            \\    lang: zig esc: none tag: #foo
            \\    -----------------------------
            \\
            \\    abc
            \\
            \\end
        }, &.{
            .{ .name = "foo", .text = "abc" },
        });
    }

    test "run multiple outputs no calls" {
        try testTangle(&.{
            \\begin
            \\
            \\    lang: zig esc: none tag: #foo
            \\    -----------------------------
            \\
            \\    abc
            \\
            \\then
            \\
            \\    lang: zig esc: none tag: #bar
            \\    -----------------------------
            \\
            \\    123
            \\
            \\end
        }, &.{
            .{ .name = "foo", .text = "abc" },
            .{ .name = "bar", .text = "123" },
        });
    }

    test "run multiple outputs common call" {
        try testTangle(&.{
            \\begin
            \\
            \\    lang: zig esc: [[]] tag: #foo
            \\    -----------------------------
            \\
            \\    [[baz]]
            \\
            \\then
            \\
            \\    lang: zig esc: [[]] tag: #bar
            \\    -----------------------------
            \\
            \\    [[baz]][[baz]]
            \\
            \\then
            \\
            \\    lang: zig esc: none tag: #baz
            \\    -----------------------------
            \\
            \\    abc
        }, &.{
            .{ .name = "baz", .text = "abc" },
            .{ .name = "bar", .text = "abcabc" },
            .{ .name = "foo", .text = "abc" },
        });
    }

    test "run multiple outputs multiple inputs" {
        try testTangle(&.{
            \\begin
            \\
            \\    lang: zig esc: [[]] tag: #foo
            \\    -----------------------------
            \\
            \\    [[baz]]
            \\
            \\end
            ,
            \\begin
            \\
            \\    lang: zig esc: [[]] tag: #bar
            \\    -----------------------------
            \\
            \\    [[baz]][[baz]]
            \\
            \\begin
            ,
            \\end
            \\
            \\    lang: zig esc: none tag: #baz
            \\    -----------------------------
            \\
            \\    abc
            \\
            \\end
        }, &.{
            .{ .name = "baz", .text = "abc" },
            .{ .name = "bar", .text = "abcabc" },
            .{ .name = "foo", .text = "abc" },
        });
    }

# Appendix. Parser primitives

    lang: zig esc: [[]] tag: #zangle parser primitives
    --------------------------------------------------

    [[parser codegen]]

    const Loc = std.builtin.SourceLocation;

    pub fn eat(p: *Parser, tag: Token.Tag, loc: Loc) ?[]const u8 {
        const state = p.it;
        const token = p.it.next();
        if (token.tag == tag) {
            return token.slice(p.it.bytes);
        } else {
            log.debug("I'm starving for a '{s}' but this is a '{s}' ({s} {d}:{d})", .{
                @tagName(tag),
                @tagName(token.tag),
                loc.fn_name,
                loc.line,
                loc.column,
            });
            p.it = state;
            return null;
        }
    }

    pub fn next(p: *Parser) ?Token {
        const token = p.it.next();
        if (token.tag != .eof) {
            return token;
        } else {
            return null;
        }
    }

    pub fn scan(p: *Parser, tag: Token.Tag) ?Token {
        while (p.next()) |token| if (token.tag == tag) {
            return token;
        };

        return null;
    }

    pub fn expect(p: *Parser, tag: Token.Tag, loc: Loc) ?void {
        _ = p.eat(tag, loc) orelse {
            log.debug("Wanted a {s}, but got nothing captain ({s} {d}:{d})", .{
                @tagName(tag),
                loc.fn_name,
                loc.line,
                loc.column,
            });
            return null;
        };
    }

    pub fn slice(p: *Parser, from: usize, to: usize) []const u8 {
        assert(from <= to);
        return p.it.bytes[from..to];
    }

    pub fn match(p: *Parser, tag: Token.Tag, text: []const u8) ?void {
        const state = p.it;
        const token = p.it.next();
        if (token.tag == tag and mem.eql(u8, token.slice(p.it.bytes), text)) {
            return;
        } else {
            p.it = state;
            return null;
        }
    }

# Appendix. Wasm interface

    lang: zig esc: none file: lib/wasm.zig
    --------------------------------------

    const std = @import("std");
    const lib = @import("lib.zig");

    const Interpreter = lib.Interpreter;
    const Parser = lib.Parser;
    const ArrayList = std.ArrayList;

    var vm: Interpreter = .{};
    var instance = std.heap.GeneralPurposeAllocator(.{}){};
    var output: ArrayList(u8) = undefined;
    const gpa = instance.allocator();

    pub export fn init() void {
        output = ArrayList(u8).init(gpa);
    }

    pub export fn add(text: [*]const u8, len: usize) i32 {
        const slice = text[0..len];
        return addInternal(slice) catch -1;
    }

    fn addInternal(text: []const u8) !i32 {
        var obj = try Parser.parse(gpa, "", text);
        errdefer obj.deinit(gpa);
        try vm.linker.objects.append(gpa, obj);
        return @intCast(i32, vm.linker.objects.items.len - 1);
    }

    pub export fn update(id: u32, text: [*]const u8, len: usize) i32 {
        const slice = text[0..len];
        updateInternal(id, slice) catch return -1;
        return 0;
    }

    fn updateInternal(id: u32, text: []const u8) !void {
        if (id >= vm.linker.objects.items.len) return error.@"Id out of range";
        const obj = try Parser.parse(gpa, "", text);
        gpa.free(vm.linker.objects.items[id].text);
        vm.linker.objects.items[id].deinit(gpa);
        vm.linker.objects.items[id] = obj;
    }

    pub export fn link() i32 {
        vm.linker.link(gpa) catch return -1;
        return 0;
    }

    pub export fn call(name: [*]const u8, len: usize) i32 {
        vm.call(gpa, name[0..len], Render, .{}) catch return -1;
        return 0;
    }

    pub export fn reset() void {
        for (vm.linker.objects.items) |obj| gpa.free(obj.text);
        vm.deinit(gpa);
        vm = .{};
    }

    const Render = struct {
        pub const Error = @TypeOf(output).Writer.Error;

        pub fn write(_: Render, v: *Interpreter, text: []const u8, nl: u16) !void {
            _ = v;
            const writer = output.writer();
            try writer.writeAll(text);
            try writer.writeByteNTimes('\n', nl);
        }

        pub fn indent(_: Render, v: *Interpreter) !void {
            const writer = output.writer();
            try writer.writeByteNTimes(' ', v.indent);
        }
    };

<!-- -->


