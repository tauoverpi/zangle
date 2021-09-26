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
const stdout = io.getStdOut().writer();

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
    graph_colours: []const u24 = &.{
        0xdf4d77,
        0x2288ed,
        0x94bd76,
        0xc678dd,
        0x61aeee,
        0xe3bd79,
    },
    command: Command,

    pub const FileOrTag = union(enum) {
        file: []const u8,
        tag: []const u8,
    };
};

const Command = enum {
    help,
    tangle,
    ls,
    call,
    graph,
    find,

    pub const map = std.ComptimeStringMap(Command, .{
        .{ "help", .help },
        .{ "tangle", .tangle },
        .{ "ls", .ls },
        .{ "call", .call },
        .{ "graph", .graph },
        .{ "find", .find },
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
    graph_colours,
    graph_background_colour,
    graph_text_colour,
    @"--",

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
        .{ "--", .@"--" },
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
    \\  --graph-border=[#rrggbb]       Select item border colour
    \\  --graph-colours=[#rrggbb,...]  Select spline colours
;

const log = std.log;

fn helpGeneric() void {
    log.info(tangle_help, .{});
    log.info(ls_help, .{});
    log.info(call_help, .{});
    log.info(graph_help, .{});
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
    }
}

fn parseCli(gpa: *Allocator, objects: *Linker.Object.List) !?Options {
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
    var graph_colours = std.ArrayList(u24).init(gpa);
    var graph_colours_set = false;

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
                    .graph_border_colour => options.graph_border_colour = try parseColour(arg[split..]),
                    .graph_background_colour => options.graph_background_colour = try parseColour(arg[split..]),
                    .graph_text_colour => options.graph_text_colour = try parseColour(arg[split..]),

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
            }
        } else {
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
        }
    }

    options.calls = calls.toOwnedSlice();
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

const FileContext = struct {
    stream: Stream,

    pub const Stream = io.BufferedWriter(1024, std.fs.File.Writer);

    pub fn init(writer: fs.File.Writer) FileContext {
        return .{ .stream = .{ .unbuffered_writer = writer } };
    }

    pub fn write(self: *FileContext, vm: *Interpreter, text: []const u8, nl: u16) !void {
        _ = vm;
        const writer = self.stream.writer();
        try writer.writeAll(text);
        try writer.writeByteNTimes('\n', nl);
    }

    pub fn indent(self: *FileContext, vm: *Interpreter) !void {
        const writer = self.stream.writer();
        try writer.writeByteNTimes(' ', vm.indent);
    }
};

pub fn main() void {
    run() catch |err| {
        log.err("{s}", .{@errorName(err)});
        os.exit(1);
    };
}

pub fn run() !void {
    var vm: Interpreter = .{};
    var instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = &instance.allocator;

    var options = (try parseCli(gpa, &vm.linker.objects)) orelse return;

    const n_objects = vm.linker.objects.items.len;
    const plural: []const u8 = if (n_objects == 1) "object" else "objects";

    log.info("linking {d} {s}...", .{ n_objects, plural });

    try vm.linker.link(gpa);

    log.info("processing command {s}", .{@tagName(options.command)});

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
            var context = FileContext.init(stdout);

            for (options.calls) |call| switch (call) {
                .file => |file| {
                    log.debug("calling file {s}", .{file});
                    try vm.callFile(gpa, file, *FileContext, &context);
                    if (!options.omit_trailing_newline) try context.stream.writer().writeByte('\n');
                },
                .tag => |tag| {
                    log.debug("calling tag {s}", .{tag});
                    try vm.call(gpa, tag, *FileContext, &context);
                },
            };

            try context.stream.flush();
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
            });

            for (vm.linker.files.keys()) |path| {
                try vm.callFile(gpa, path, *GraphContext, &context);
            }

            for (vm.linker.procedures.keys()) |proc| {
                if (!context.target.contains(proc.ptr)) {
                    try vm.call(gpa, proc, *GraphContext, &context);
                }
            }

            try context.end();

            try context.stream.flush();
        },

        .tangle => for (vm.linker.files.keys()) |path| {
            const file = try createFile(path, options);
            defer file.close();

            var context = FileContext.init(file.writer());

            try vm.callFile(gpa, path, *FileContext, &context);
            if (!options.omit_trailing_newline) try context.stream.writer().writeByte('\n');
            try context.stream.flush();
        },
    }
}

fn createFile(path: []const u8, options: Options) !fs.File {
    var tmp: [fs.MAX_PATH_BYTES]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tmp);
    var filename = path;

    if (mem.startsWith(u8, filename, "~/")) {
        filename = try fs.path.join(&fba.allocator, &.{
            os.getenv("HOME") orelse return error.@"unable to find ~/",
            filename[2..],
        });
    }

    if (path[0] == '/' and !options.allow_absolute_paths) {
        return error.@"Absolute paths disabled; use --allow-absolute-paths to enable them.";
    }

    if (fs.path.dirname(path)) |dir| try fs.cwd().makePath(dir);

    log.info("writing file: {s}", .{filename});
    return try fs.cwd().createFile(path, .{ .truncate = true });
}
