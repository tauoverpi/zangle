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
