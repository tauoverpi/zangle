const std = @import("std");
const lib = @import("lib");

const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const meta = std.meta;
const fs = std.fs;
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

const Options = struct {
    allow_absolute_paths: bool = false,
    omit_trailing_newline: bool = false,
    list_files: bool = false,
    list_tags: bool = false,
    calls: []const FileOrTag = &.{},
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

    pub const map = std.ComptimeStringMap(Command, .{
        .{ "help", .help },
        .{ "tangle", .tangle },
        .{ "ls", .ls },
        .{ "call", .call },
    });
};

const Flag = enum {
    allow_absolute_paths,
    omit_trailing_newline,
    file,
    tag,
    list_tags,
    list_files,
    @"--",

    pub const map = std.ComptimeStringMap(Flag, .{
        .{ "--allow-absolute-paths", .allow_absolute_paths },
        .{ "--omit-trailing-newline", .omit_trailing_newline },
        .{ "--file=", .file },
        .{ "--tag=", .tag },
        .{ "--list-tags", .list_tags },
        .{ "--list-files", .list_files },
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

const log = std.log;

fn helpGeneric() void {
    log.info(tangle_help, .{});
    log.info(ls_help, .{});
    log.info(call_help, .{});
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
            const object = try Parser.parse(gpa, text);

            objects.append(gpa, object) catch return error.@"Exhausted memory";
        }
    }

    options.calls = calls.toOwnedSlice();
    return options;
}

const FileContext = struct {
    stream: Stream,

    pub const Stream = io.BufferedWriter(1024, std.fs.File.Writer);

    pub fn init(writer: fs.File.Writer) FileContext {
        return .{ .stream = .{ .unbuffered_writer = writer } };
    }

    pub fn write(self: *FileContext, text: []const u8, index: u32, nl: u16) !void {
        _ = index;
        const writer = self.stream.writer();
        try writer.writeAll(text);
        try writer.writeByteNTimes('\n', nl);
    }

    pub fn indent(self: *FileContext, len: u16) !void {
        const writer = self.stream.writer();
        try writer.writeByteNTimes(' ', len);
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

    switch (options.command) {
        .help => unreachable,

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

    log.debug("writing file: {s}", .{filename});
    return try fs.cwd().createFile(path, .{ .truncate = true });
}
