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

pub fn step(vm: *Interpreter, gpa: *Allocator, comptime T: type, eval: T) !bool {
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

fn execRet(vm: *Interpreter, comptime T: type, data: Instruction.Data.Ret, eval: T) !bool {
    const name = vm.linker.objects.items[vm.module - 1]
        .text[data.start .. data.start + data.len];

    if (vm.stack.popOrNull()) |location| {
        const mod = vm.module;
        const ip = vm.ip;

        vm.ip = location.value.ip;
        vm.module = location.value.module;
        vm.indent -= location.value.indent;

        if (@hasDecl(Child(T), "ret")) try eval.ret(
            vm.ip,
            vm.module,
            vm.indent,
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

    if (@hasDecl(Child(T), "terminate")) try eval.terminate(name);
    log.debug("[mod {d} ip {x:0>8}] terminate(identifier '{s}')", .{
        vm.module,
        vm.ip,
        name,
    });

    return false;
}
fn execJmp(vm: *Interpreter, comptime T: type, data: Instruction.Data.Jmp, eval: T) !void {
    const mod = vm.module;
    const ip = vm.ip;

    if (data.module != 0) {
        vm.module = data.module;
    }

    vm.ip = data.address;

    if (@hasDecl(Child(T), "jmp")) try eval.jmp(vm.ip, data.address);
    if (@hasDecl(Child(T), "write")) try eval.write("\n", 0, 0);

    log.debug("[mod {d} ip {x:0>8}] jmp(mod {d}, address {x:0>8})", .{
        mod,
        ip,
        vm.module,
        vm.ip,
    });

    vm.last_is_newline = true;
}
fn execCall(vm: *Interpreter, comptime T: type, data: Instruction.Data.Call, gpa: *Allocator, eval: T) !void {
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

    if (@hasDecl(Child(T), "call")) try eval.call(vm.ip, vm.module, vm.indent);
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
    if (@hasDecl(Child(T), "shell")) try eval.shell();
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
) !void {
    if (vm.should_indent and vm.last_is_newline) {
        if (@hasDecl(Child(T), "indent")) try eval.indent(vm.indent);
        log.debug("[mod {d} ip {x:0>8}] indent(len {d})", .{
            vm.module,
            vm.ip,
            vm.indent,
        });
    } else {
        vm.should_indent = true;
    }

    if (@hasDecl(Child(T), "write")) try eval.write(
        text[data.start .. data.start + data.len],
        data.start,
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

    pub const Stream = std.io.FixedBufferStream([]u8);

    pub fn write(self: *Test, text: []const u8, index: u32, nl: u16) !void {
        _ = index;
        const writer = self.stream.writer();
        try writer.writeAll(text);
        try writer.writeByteNTimes('\n', nl);
    }

    pub fn indent(self: *Test, len: u16) !void {
        const writer = self.stream.writer();
        try writer.writeByteNTimes(' ', len);
    }

    pub fn expect(self: *Test, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, self.stream.getWritten());
    }
};

pub fn deinit(vm: *Interpreter, gpa: *Allocator) void {
    vm.linker.deinit(gpa);
    vm.stack.deinit(gpa);
}

fn Child(comptime T: type) type {
    switch (@typeInfo(T)) {
        .Pointer => |info| return info.child,
        else => return T,
    }
}

pub fn call(vm: *Interpreter, gpa: *Allocator, symbol: []const u8, comptime T: type, eval: T) !void {
    if (vm.linker.procedures.get(symbol)) |sym| {
        vm.ip = sym.entry;
        vm.module = sym.module;
        vm.indent = 0;
        log.debug("calling {s} address {x:0>8} module {d}", .{ symbol, vm.ip, vm.module });
        while (try vm.step(gpa, T, eval)) {}
    } else return error.@"Unknown procedure";
}

pub fn callFile(vm: *Interpreter, gpa: *Allocator, symbol: []const u8, comptime T: type, eval: T) !void {
    if (vm.linker.files.get(symbol)) |sym| {
        vm.ip = sym.entry;
        vm.module = sym.module;
        vm.indent = 0;
        log.debug("calling {s} address {x:0>8} module {d}", .{ symbol, vm.ip, vm.module });
        while (try vm.step(gpa, T, eval)) {}
    } else return error.@"Unknown procedure";
}
