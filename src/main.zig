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

const Options = struct {
    allow_absolute_paths: bool = false,
    execute_shell_filters: bool = false,
    omit_trailing_newline: bool = false,
};

const Command = enum {
    invalid,
    help,
    tangle,

    pub const map = std.ComptimeStringMap(Command, .{
        .{ "help", .help },
        .{ "tangle", .tangle },
    });
};

const Flag = enum {
    allow_absolute_paths,
    execute_shell_filters,
    omit_trailing_newline,

    pub const map = std.ComptimeStringMap(Flag, .{
        .{ "--allow-absolute-paths", .allow_absolute_paths },
        .{ "--execute-shell-filters", .execute_shell_filters },
        .{ "--omit-trailing-newline", .omit_trailing_newline },
    });
};

const tangle_help =
    \\Usage: zangle tangle [options] [files]
    \\
    \\  --allow-absolute-paths
    \\  --execute-shell-filters
    \\  --omit-trailing-newline
    \\
;

const generic_help = tangle_help;
const log = std.log;

fn help(com: Command, name: ?[]const u8) void {
    switch (com) {
        .help => log.info(generic_help, .{}),
        .invalid => {
            log.info(generic_help, .{});
            log.err("I don't know how to handle the given command '{s}'", .{name.?});
        },
        .tangle => log.info(tangle_help, .{}),
    }
}

fn parseCli(gpa: *Allocator, objects: *Linker.Object.List) !?Options {
    var options: Options = .{};
    const args = os.argv;

    if (args.len < 2) {
        help(.help, null);
        return error.@"Missing command name";
    }

    const command_name = mem.sliceTo(args[1], 0);
    const command = Command.map.get(command_name) orelse .invalid;

    if (args.len < 3 or command == .invalid or command == .help) {
        help(command, command_name);
        switch (command) {
            .help => return null,
            .invalid => return error.@"Invalid command",
            else => return error.@"Not enough arguments",
        }
    }

    switch (command) {
        .help, .invalid => unreachable,

        .tangle => for (args[2..]) |arg0| {
            const arg = mem.sliceTo(arg0, 0);
            if (arg.len == 0) continue;

            if (arg[0] == '-') {
                const split = mem.indexOfScalar(u8, arg, '=') orelse arg.len;
                const flag = Flag.map.get(arg[0..split]) orelse {
                    log.err("unknown option '{s}'", .{arg});
                    return error.@"Unknown command-line flag";
                };

                switch (flag) {
                    .allow_absolute_paths => options.allow_absolute_paths = true,
                    .execute_shell_filters => options.execute_shell_filters = true,
                    .omit_trailing_newline => options.omit_trailing_newline = true,
                }
            } else {
                std.log.info("compiling {s}", .{arg});
                const text = try fs.cwd().readFileAlloc(gpa, arg, 0x7fff_ffff);
                const object = try Parser.parse(gpa, text);

                objects.append(gpa, object) catch return error.@"Exhausted memory";
            }
        } else if (objects.items.len == 0) {
            help(.tangle, null);
            return error.@"No input files specified";
        },
    }

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

    const options = (try parseCli(gpa, &vm.linker.objects)) orelse return;

    const n_objects = vm.linker.objects.items.len;
    const plural: []const u8 = if (n_objects == 1) "object" else "objects";

    log.info("linking {d} {s}...", .{ n_objects, plural });

    try vm.linker.link(gpa);

    for (vm.linker.files.keys()) |path| {
        const file = try createFile(path, options);
        defer file.close();

        var render = FileContext.init(file.writer());

        try vm.callFile(gpa, path, *FileContext, &render);
        if (!options.omit_trailing_newline) try render.stream.writer().writeByte('\n');
        try render.stream.flush();
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
