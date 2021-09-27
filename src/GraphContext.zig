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
gpa: *Allocator,
colour: u8 = 0,
target: Target = .{},
text_colour: u24 = 0,
inherit: bool = false,
colours: []const u24 = &.{},

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

pub fn init(gpa: *Allocator, writer: fs.File.Writer) GraphContext {
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
}

pub fn end(self: *GraphContext) !void {
    try self.stream.writer().writeAll("}\n");
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
                .colour = self.colour,
            });
        }
    }

    for (sub_nodes) |sub| {
        const entry = try self.omit.getOrPut(self.gpa, .{
            .from = name.ptr,
            .to = sub.ptr,
        });

        if (!entry.found_existing) {
            const colour = self.target.get(sub.ptr).?;
            const selected = if (self.colours.len == 0)
                0
            else
                self.colours[colour % self.colours.len];

            try writer.print("    \"{s}\" -- ", .{name});
            try writer.print("\"{s}\"[color = \"#{x:0>6}\"];\n", .{
                sub,
                selected,
            });
        }
    }
}
