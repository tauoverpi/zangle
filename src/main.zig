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

pub const log_level = .info;

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
    graphviz,

    pub const map = std.ComptimeStringMap(Command, .{
        .{ "help", .help },
        .{ "tangle", .tangle },
        .{ "ls", .ls },
        .{ "call", .call },
        .{ "graphviz", .graphviz },
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

const graphviz_help =
    \\Usage: zangle graphviz [files]
;

const log = std.log;

fn helpGeneric() void {
    log.info(tangle_help, .{});
    log.info(ls_help, .{});
    log.info(call_help, .{});
    log.info(graphviz_help, .{});
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
        .graphviz => log.info(graphviz_help, .{}),
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

                .graphviz => return error.@"Unknown command-line flag",

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

const GraphvizContext = struct {
    stream: Stream,
    stack: Stack = .{},
    omit: Omit = .{},
    gpa: *Allocator,
    colour: u8 = 0,
    target: Target = .{},

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

    pub fn init(gpa: *Allocator, writer: fs.File.Writer) GraphvizContext {
        return .{
            .stream = .{ .unbuffered_writer = writer },
            .gpa = gpa,
        };
    }

    pub fn begin(self: *GraphvizContext) !void {
        try self.stream.writer().writeAll(
            \\graph G {
            \\    overlap = false;
            \\    rankdir = LR;
            \\    concentrate = true;
            \\    node[shape = rectangle, color = "#92abc9"];
            \\
        );
        try self.stack.append(self.gpa, .{});
    }

    pub fn end(self: *GraphvizContext) !void {
        try self.stream.writer().writeAll("}\n");
    }

    pub fn call(self: *GraphvizContext, ip: u32, module: u16, indent: u16) !void {
        _ = ip;
        _ = module;
        _ = indent;
        try self.stack.append(self.gpa, .{});
    }

    pub fn ret(self: *GraphvizContext, ip: u32, module: u16, indent: u16, name: []const u8) !void {
        _ = ip;
        _ = module;
        _ = indent;

        try self.render(name);

        var old = self.stack.pop();
        old.list.deinit(self.gpa);

        try self.stack.items[self.stack.items.len - 1].list.append(self.gpa, name);
    }

    pub fn terminate(self: *GraphvizContext, name: []const u8) !void {
        try self.render(name);

        self.stack.items[0].list.clearRetainingCapacity();

        assert(self.stack.items.len == 1);
    }

    const colours: []const u24 = &.{
        0xdf4d77,
        0x2288ed,
        0x94bd76,
        0xc678dd,
        0x61aeee,
        0xe3bd79,
    };

    fn render(self: *GraphvizContext, name: []const u8) !void {
        const writer = self.stream.writer();
        const sub_nodes = self.stack.items[self.stack.items.len - 1].list.items;

        var valid: usize = 0;
        for (sub_nodes) |sub| {
            if (!self.omit.contains(.{ .from = name.ptr, .to = sub.ptr })) {
                valid += 1;
            }
        }

        if (valid == 0) {
            try writer.print("    \"{s}\";", .{name});
        } else {
            for (sub_nodes) |sub| {
                const entry = try self.omit.getOrPut(self.gpa, .{
                    .from = name.ptr,
                    .to = sub.ptr,
                });

                if (!entry.found_existing) {
                    const colour = try self.target.getOrPut(self.gpa, sub.ptr);
                    if (!colour.found_existing) {
                        colour.value_ptr.* = self.colour;
                        self.colour +%= 1;
                    }

                    try writer.print("    \"{s}\" -- ", .{name});
                    try writer.print("\"{s}\"[color = \"#{x:0>6}\"]", .{
                        sub,
                        colours[colour.value_ptr.* % colours.len],
                    });
                    try writer.writeAll(";\n");
                }
            }
        }
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

        .graphviz => {
            var context = GraphvizContext.init(gpa, stdout);

            try context.begin();
            for (vm.linker.files.keys()) |path| {
                try vm.callFile(gpa, path, *GraphvizContext, &context);
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
