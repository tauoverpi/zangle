const std = @import("std");
const lib = @import("lib.zig");
const testing = std.testing;
const assert = std.debug.assert;

const Parser = lib.Parser;
const Instruction = lib.Instruction;
const ArrayList = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;
const StringMap = std.StringArrayHashMapUnmanaged;
const Linker = @This();

objects: Object.List = .{},
generation: u16 = 1,
procedures: ProcedureMap = .{},
files: FileMap = .{},

const ProcedureMap = StringMap(Procedure);
const FileMap = StringMap(Procedure);
const Procedure = struct {
    entry: u32,
    module: u16,
};

const log = std.log.scoped(.linker);

pub fn deinit(l: *Linker, gpa: *Allocator) void {
    for (l.objects.items) |*obj| obj.deinit(gpa);
    l.objects.deinit(gpa);
    l.procedures.deinit(gpa);
    l.files.deinit(gpa);
    l.generation = undefined;
}

pub const Object = struct {
    text: []const u8,
    program: Instruction.List = .{},
    symbols: SymbolMap = .{},
    adjacent: AdjacentMap = .{},
    files: Object.FileMap = .{},

    pub const List = ArrayList(Object);
    pub const SymbolMap = StringMap(SymbolList);
    pub const FileMap = StringMap(u32);
    pub const SymbolList = ArrayList(u32);
    pub const AdjacentMap = StringMap(Adjacent);

    pub const Adjacent = struct {
        entry: u32,
        exit: u32,
    };

    pub fn deinit(self: *Object, gpa: *Allocator) void {
        self.program.deinit(gpa);

        for (self.symbols.values()) |*entry| entry.deinit(gpa);
        self.symbols.deinit(gpa);
        self.adjacent.deinit(gpa);
        self.files.deinit(gpa);
    }
};

fn mergeAdjacent(l: *Linker) void {
    for (l.objects.items) |*obj, module| {
        log.debug("processing module {d}", .{module + 1});
        const values = obj.adjacent.values();
        for (obj.adjacent.keys()) |key, i| {
            const opcodes = obj.program.items(.opcode);
            const data = obj.program.items(.data);
            const exit = values[i].exit;
            log.debug("opcode {}", .{opcodes[exit]});

            switch (opcodes[exit]) {
                .ret, .jmp => {
                    if (opcodes[exit] == .jmp and data[exit].jmp.generation == l.generation) continue;
                    var last_adj = values[i];
                    var last_obj = obj;

                    for (l.objects.items[module + 1 ..]) |*next, offset| {
                        if (next.adjacent.get(key)) |current| {
                            const op = last_obj.program.items(.opcode)[last_adj.exit];
                            assert(op == .jmp or op == .ret);

                            const destination = @intCast(u16, module + offset) + 2;
                            log.debug("updating jump location to address 0x{x:0>8} in module {d}", .{
                                current.entry,
                                destination,
                            });

                            last_obj.program.items(.opcode)[last_adj.exit] = .jmp;
                            last_obj.program.items(.data)[last_adj.exit] = .{ .jmp = .{
                                .generation = l.generation,
                                .address = current.entry,
                                .module = destination,
                            } };
                            last_adj = current;
                            last_obj = next;
                        }
                    }
                },

                else => unreachable,
            }
        }
    }
}

test "merge" {
    var obj_a = try Parser.parse(testing.allocator,
        \\
        \\
        \\    lang: zig esc: none tag: #a
        \\    ---------------------------
        \\
        \\    abc
        \\
        \\end
        \\
        \\    lang: zig esc: none tag: #b
        \\    ---------------------------
        \\
        \\    abc
        \\
        \\end
    );

    var obj_b = try Parser.parse(testing.allocator,
        \\
        \\
        \\    lang: zig esc: none tag: #a
        \\    ---------------------------
        \\
        \\    abc
        \\
        \\end
    );

    var obj_c = try Parser.parse(testing.allocator,
        \\
        \\
        \\    lang: zig esc: none tag: #b
        \\    ---------------------------
        \\
        \\    abc
        \\
        \\end
    );

    var l: Linker = .{};
    defer l.deinit(testing.allocator);

    try l.objects.appendSlice(testing.allocator, &.{
        obj_a,
        obj_b,
        obj_c,
    });

    l.mergeAdjacent();

    try testing.expectEqualSlices(Instruction.Opcode, &.{ .write, .jmp, .write, .jmp }, obj_a.program.items(.opcode));

    try testing.expectEqual(
        Instruction.Data.Jmp{
            .module = 2,
            .address = 0,
            .generation = 1,
        },
        obj_a.program.items(.data)[1].jmp,
    );

    try testing.expectEqual(
        Instruction.Data.Jmp{
            .module = 3,
            .address = 0,
            .generation = 1,
        },
        obj_a.program.items(.data)[3].jmp,
    );
}
fn buildProcedureTable(l: *Linker, gpa: *Allocator) !void {
    log.debug("building procedure table", .{});
    for (l.objects.items) |obj, module| {
        log.debug("processing module {d} with {d} procedures", .{ module + 1, obj.adjacent.keys().len });
        for (obj.adjacent.keys()) |key, i| {
            const entry = try l.procedures.getOrPut(gpa, key);
            if (!entry.found_existing) {
                const entry_point = obj.adjacent.values()[i].entry;
                log.debug("registering new procedure '{s}' address {x:0>8} module {d}", .{ key, entry_point, module + 1 });

                entry.value_ptr.* = .{
                    .module = @intCast(u16, module) + 1,
                    .entry = @intCast(u32, entry_point),
                };
            }
        }
    }
    log.debug("registered {d} procedures", .{l.procedures.count()});
}
fn updateProcedureCalls(l: *Linker) void {
    log.debug("updating procedure calls", .{});
    for (l.procedures.keys()) |key, i| {
        const proc = l.procedures.values()[i];
        for (l.objects.items) |*obj| if (obj.symbols.get(key)) |sym| {
            log.debug("updating locations {any}", .{sym.items});
            for (sym.items) |location| {
                assert(obj.program.items(.opcode)[location] == .call);
                const call = &obj.program.items(.data)[location].call;
                call.address = proc.entry;
                call.module = proc.module;
            }
        };
    }
}
fn buildFileTable(l: *Linker, gpa: *Allocator) !void {
    for (l.objects.items) |obj, module| {
        for (obj.files.keys()) |key, i| {
            const file = try l.files.getOrPut(gpa, key);
            if (file.found_existing) return error.@"Multiple files with the same name";
            file.value_ptr.module = @intCast(u16, module) + 1;
            file.value_ptr.entry = obj.files.values()[i];
        }
    }
}
pub fn link(l: *Linker, gpa: *Allocator) !void {
    l.procedures.clearRetainingCapacity();
    l.files.clearRetainingCapacity();

    try l.buildProcedureTable(gpa);
    try l.buildFileTable(gpa);

    l.mergeAdjacent();
    l.updateProcedureCalls();

    var failure = false;
    for (l.objects.items) |obj| {
        for (obj.symbols.keys()) |key| {
            if (!l.procedures.contains(key)) {
                failure = true;
                log.err("unknown symbol '{s}'", .{key});
            }
        }
    }

    if (failure) return error.@"Unknown symbol";
}

test "call" {
    var obj = try Parser.parse(testing.allocator,
        \\
        \\
        \\    lang: zig esc: none tag: #a
        \\    ---------------------------
        \\
        \\    abc
        \\
        \\end
        \\
        \\    lang: zig esc: [[]] tag: #b
        \\    ---------------------------
        \\
        \\    [[a]]
        \\
        \\end
    );

    var l: Linker = .{};
    defer l.deinit(testing.allocator);

    try l.objects.append(testing.allocator, obj);
    try l.link(testing.allocator);

    try testing.expectEqualSlices(
        Instruction.Opcode,
        &.{ .write, .ret, .call, .ret },
        obj.program.items(.opcode),
    );

    try testing.expectEqual(
        Instruction.Data.Call{
            .address = 0,
            .module = 1,
            .indent = 0,
        },
        obj.program.items(.data)[2].call,
    );
}
