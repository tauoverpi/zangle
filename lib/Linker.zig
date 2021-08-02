const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;
const log = std.log.scoped(.linker);
const Allocator = std.mem.Allocator;
const Linker = @This();
const Compiler = @import("Compiler.zig"); // for tests

// TODO: figure out how to do most of this without memory allocation

objects: ObjectList = .{},
files: OutputFileMap = .{},
procedures: ProcedureMap = .{},

const OutputFileMap = std.StringArrayHashMapUnmanaged(OutputFile);

const OutputFile = struct {
    entry: u32,
    module: u16,
};

const ProcedureMap = std.StringArrayHashMapUnmanaged(Procedure);

const Procedure = struct {
    entry: u32,
    module: u16,
};

pub const ObjectList = std.ArrayListUnmanaged(Object);
pub const Object = struct {
    /// Map of external symbols
    symbols: SymbolMap,

    /// Map of adjacent blocks
    adjacent: AdjacentMap,

    /// Map of file roots
    files: FileMap,

    bytecode: []u8,

    text: []const u8,

    /// Mapping between unresolved symbols and locations which
    /// need to be updated to point to the correct address once
    /// resolved. All locations are relative to the start of the
    /// bytecode stream.
    pub const SymbolMap = std.StringArrayHashMapUnmanaged(SymbolEntry);

    pub const SymbolEntry = struct {
        locations: SymbolList = .{},

        pub const SymbolList = std.ArrayListUnmanaged(u32);
    };

    pub const AdjacentMap = std.StringArrayHashMapUnmanaged(Adjacent);
    pub const Adjacent = struct {
        module_entry: u32,
        module_exit: u32,
    };

    pub const FileMap = std.StringArrayHashMapUnmanaged(u32);

    pub fn deinit(obj: *Object, gpa: *Allocator) void {
        for (obj.symbols.values()) |*symbol| {
            symbol.locations.deinit(gpa);
        }
        obj.symbols.deinit(gpa);
        obj.adjacent.deinit(gpa);
        obj.files.deinit(gpa);
        gpa.free(obj.bytecode);
    }
};

pub fn link(l: *Linker, gpa: *Allocator) !void {
    for (l.objects.items) |obj, offset| {
        const module = offset + 1;

        const procs = l.procedures.count();
        const files = l.files.count();

        try l.insert(gpa, @intCast(u16, module), obj);

        log.debug("new module {} with {} procedures and {} files", .{
            module,
            l.procedures.count() - procs,
            l.files.count() - files,
        });
    }

    l.patchCallSites();
}

pub fn update(l: *Linker, module: u16, obj: Object) !void {
    l.remove(gpa, l.objects.items[module]);
    try l.insert(gpa, module, obj);
    // TODO: relink adjacent nodes
    // TODO: patch sites (again)
}

// fn mergeAdjacentBlocks(l: *Linker) !void {}

fn patchCallSites(l: *Linker) void {
    for (l.objects.items) |object, m| {
        log.debug("patching module {d}", .{m + 1});
        const procs = l.procedures.values();
        for (l.procedures.keys()) |key, i| {
            if (object.symbols.get(key)) |entry| {
                for (entry.locations.items) |location| {
                    mem.writeIntSliceBig(u32, object.bytecode[location .. location + 4], procs[i].entry);
                    mem.writeIntSliceBig(u16, object.bytecode[location + 4 .. location + 6], procs[i].module);
                }
            }
        } else log.debug("patched {d} call sites", .{i});
    }
}

/// Insert a new object into the linker object table with the given module name.
fn insert(l: *Linker, gpa: *Allocator, module: u16, obj: Object) !void {
    const values = obj.files.values();
    const keys = obj.files.keys();

    for (keys) |key, i| {
        // clear invalidated files
        errdefer for (keys[0..i]) |k| assert(l.files.swapRemove(k));

        // file entries must be unique over the entire project
        const entry = try l.files.getOrPut(gpa, key);
        if (entry.found_existing) return error.@"Duplicate file block found during linking";
        log.debug("new output {s}", .{key});

        entry.value_ptr.* = .{
            .entry = values[i],
            .module = module,
        };
    }

    // fill the procedure map
    const adjacent = obj.adjacent.values();
    for (obj.adjacent.keys()) |key, i| {
        const proc = try l.procedures.getOrPut(gpa, key);
        if (proc.found_existing) {
            if (module < proc.value_ptr.module) {
                proc.value_ptr.entry = adjacent[i].module_entry;
                proc.value_ptr.module = module;
            }
        } else {
            log.debug("new procedure {s}", .{key});
            proc.value_ptr.entry = adjacent[i].module_entry;
            proc.value_ptr.module = module;
        }
    }
}

/// Remove an entry from the linker object table.
fn remove(l: *Linker, obj: Object) void {
    for (obj.files.keys()) |key| assert(l.files.swapRemove(key));
}

pub fn deinit(l: *Linker, gpa: *Allocator) void {
    l.files.deinit(gpa);
    l.procedures.deinit(gpa);
    for (l.objects.items) |*obj| obj.deinit(gpa);
    l.objects.deinit(gpa);
    l.* = undefined;
}

test "linker add object" {
    var obj = try Compiler.parseAndCompile(testing.allocator,
        \\    lang: txt esc: <<>> file: /tmp/txt
        \\    ----------------------------------
        \\
        \\    <<example>>
        \\
        \\---
        \\
        \\    lang: txt esc: none tag: #example
        \\    ---------------------------------
        \\
        \\    example
    );

    var l: Linker = .{};
    defer l.deinit(testing.allocator);

    try l.objects.append(testing.allocator, obj);
    try l.insert(testing.allocator, 0, obj);

    try testing.expectError(
        error.@"Duplicate file block found during linking",
        l.insert(testing.allocator, 0, obj),
    );

    l.remove(obj);
}
