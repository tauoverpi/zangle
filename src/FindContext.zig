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
