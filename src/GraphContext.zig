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

            try writer.print(
                \\#{x:0>6}"];
                \\
            , .{selected.to});
        }
    }
}
