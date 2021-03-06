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
