const std = @import("std");
const assert = std.debug.assert;
const meta = std.meta;
const io = std.io;
const mem = std.mem;
const testing = std.testing;
const log = std.log.scoped(.interpreter);

const Interpreter = @This();
const Linker = @import("Linker.zig");
const Compiler = @import("Compiler.zig");
const Allocator = std.mem.Allocator;

ip: u32,
module: u16,
stack: ReturnStack = .{},
linker: Linker,
delay_indent: bool = true,

const ReturnStack = std.ArrayListUnmanaged(Location);
const Location = struct {
    ip: u32,
    module: u16,
    indentation: u16,
};

pub const Bytecode = enum(u8) {
    //! A module address of 0 indicates that the instruction is to be run in the local
    //! address space rather than that of another module. Thus the first module is 1.

    /// Pop return location from the stack and jump to it.
    ret,

    /// Push return location to stack and jump to the given address.
    ///
    /// Parameters:
    ///   - procedure address
    ///   - module identifier
    call,

    /// Jump to the given address without pushing a return location.
    /// This instruction is used to merge adjacent (same tag) blocks.
    ///
    /// Parameters:
    ///   - address
    ///   - module identifier
    jmp,

    /// Write a line of text.
    ///
    /// Parameters:
    ///   - start of line
    ///   - length of line
    write,

    /// Write a single newline character.
    write_nl,

    /// Push return location to stack and jump to the given address
    /// where upon return the output is piped through an external
    /// program.
    ///
    /// Parameters:
    ///   - procedure address
    ///   - module identifier
    ///   - shell command (zero terminated)
    shell,

    /// Push return location to stack and jump to the given address
    /// where upon return the output is filtered via the given built-in
    /// function.
    ///
    /// Parameters:
    ///   - procedure address
    ///   - module identifier
    ///   - built-in command (zero terminated)
    command,

    _,

    pub fn code(b: Bytecode) u8 {
        const int = @enumToInt(b);
        assert(int <= @enumToInt(Bytecode.command));
        return int;
    }
};

pub fn deinit(r: *Interpreter, gpa: *Allocator) void {
    r.stack.deinit(gpa);
}

fn step(r: *Interpreter, gpa: *Allocator, writer: anytype) !bool {
    const object = r.linker.objects.items[r.module - 1];
    const opcode = @intToEnum(Bytecode, object.bytecode[r.ip]);
    r.ip += 1;

    switch (opcode) {
        .ret => if (r.stack.popOrNull()) |location| {
            const ip = r.ip;
            const module = r.module;
            r.ip = location.ip;
            r.module = location.module;
            log.debug("{s: <8} ip: {x: <4} module: {x: <4} (address: {x} module: {x})", .{
                @tagName(opcode),
                ip,
                module,
                r.ip,
                r.module,
            });
        } else return false,

        .call, .shell, .command => {
            const ip = mem.readIntSliceBig(u32, object.bytecode[r.ip .. r.ip + 4]);
            const module = mem.readIntSliceBig(u16, object.bytecode[r.ip + 4 .. r.ip + 6]);
            const indentation = mem.readIntSliceBig(u16, object.bytecode[r.ip + 6 .. r.ip + 8]);
            log.debug("{s: <8} ip: {x: <4} module: {x: <4} (address: {x} module: {x} indentation: {d})", .{
                @tagName(opcode),
                r.ip - 1,
                r.module,
                ip,
                module,
                indentation,
            });

            var offset: u32 = 8;

            switch (opcode) {
                .call => {},
                // TODO: handle commands
                .shell, .command => offset += 4,
                else => unreachable,
            }

            const location: Location = .{
                .ip = r.ip + offset,
                .module = r.module,
                .indentation = indentation,
            };

            r.delay_indent = true;
            r.ip = ip;
            if (module != 0) r.module = module;
            try r.stack.append(gpa, location);
        },

        .jmp => {
            const ip = r.ip - 1;
            const module = r.module;
            r.ip = mem.readIntSliceBig(u32, object.bytecode[r.ip .. r.ip + 4]);
            r.module = mem.readIntSliceBig(u16, object.bytecode[r.ip + 4 .. r.ip + 6]);
            log.debug("{s: <8} ip: {x: <4} module: {x: <4} (address: {x} module: {x})", .{
                @tagName(opcode),
                ip,
                module,
                r.ip,
                r.module,
            });
        },

        .write_nl => {
            try writer.writeByteNTimes('\n', object.bytecode[r.ip]);
            log.debug("{s: <8} ip: {x: <4} module: {x: <4} (len: {d})", .{
                @tagName(opcode),
                r.ip - 1,
                r.module,
                object.bytecode[r.ip],
            });
            r.ip += 1;
        },

        .write => {
            if (r.delay_indent) {
                r.delay_indent = false;
            } else if (r.stack.items.len > 0) {
                const frame = r.stack.items[r.stack.items.len - 1];
                try writer.writeByteNTimes(' ', frame.indentation);
            }
            const index = mem.readIntSliceBig(u32, object.bytecode[r.ip .. r.ip + 4]);
            const len = mem.readIntSliceBig(u16, object.bytecode[r.ip + 4 .. r.ip + 6]);
            try writer.writeAll(object.text[index .. index + len]);
            log.debug("{s: <8} ip: {x: <4} module: {x: <4} (text: `{s}')", .{
                @tagName(opcode),
                r.ip - 1,
                r.module,
                object.text[index .. index + len],
            });

            r.ip += 6;
        },

        _ => unreachable, // illegal opcode executed
    }

    return true;
}

// fn call(r: *Interpreter, tag: []const u8, writer: anytype) !void {}

fn testCompareOutput(gpa: *Allocator, inputs: []const []const u8, expected: anytype) !void {
    var l: Linker = .{};
    defer l.deinit(gpa);

    for (inputs) |input| {
        var obj = try Compiler.parseAndCompile(gpa, input);

        try l.objects.append(gpa, obj);
    }
    try l.link(gpa);

    var r: Interpreter = .{ .linker = l, .ip = 0, .module = 1 };
    defer r.deinit(gpa);

    inline for (meta.fields(@TypeOf(expected))) |field| {
        const file = l.files.get(field.name).?;
        r.ip = file.entry;
        r.module = file.module;

        var buffer: [@field(expected, field.name).len]u8 = undefined;
        var fbs = io.fixedBufferStream(&buffer);

        errdefer std.log.err("{s}", .{fbs.getWritten()});
        while (try r.step(gpa, fbs.writer())) {}
        try testing.expectEqualStrings(@field(expected, field.name), fbs.getWritten());
    }
}

test "run single" {
    try testCompareOutput(testing.allocator, &.{
        \\    lang: zig esc: none file: example.zig
        \\    -------------------------------------
        \\
        \\    pub fn main() void {
        \\        std.log.info("Hello, world!", .{});
        \\    }
    }, .{
        .@"example.zig" = 
        \\pub fn main() void {
        \\    std.log.info("Hello, world!", .{});
        \\}
        ,
    });
}

test "run call" {
    try testCompareOutput(testing.allocator, &.{
        \\    lang: zig esc: <<>> file: example.zig
        \\    -------------------------------------
        \\
        \\    pub fn main() void {
        \\        <<example>>
        \\    }
        \\
        \\---
        \\
        \\    lang: zig esc: none tag: #example
        \\    ---------------------------------
        \\
        \\    std.log.info("Hello, world!", .{});
    }, .{
        .@"example.zig" = 
        \\pub fn main() void {
        \\    std.log.info("Hello, world!", .{});
        \\}
        ,
    });
}

test "run call indentation" {
    try testCompareOutput(testing.allocator, &.{
        \\    lang: zig esc: <<>> file: example.zig
        \\    -------------------------------------
        \\
        \\    pub fn main() void {
        \\        <<example>>
        \\    }
        \\
        \\---
        \\
        \\    lang: zig esc: none tag: #example
        \\    ---------------------------------
        \\
        \\    std.log.info("Hello, world!", .{});
        \\    std.log.info("Hello, world!", .{});
    }, .{
        .@"example.zig" = 
        \\pub fn main() void {
        \\    std.log.info("Hello, world!", .{});
        \\    std.log.info("Hello, world!", .{});
        \\}
        ,
    });
}

test "run multiple files" {
    try testCompareOutput(testing.allocator, &.{
        \\    lang: zig esc: none file: example.zig
        \\    -------------------------------------
        \\
        \\    pub fn main() void {
        \\        std.log.info("Hello, ", .{});
        \\    }
        \\
        \\---
        \\
        \\    lang: zig esc: none file: example2.zig
        \\    --------------------------------------
        \\
        \\    pub fn main() void {
        \\        std.log.info("world!", .{});
        \\    }
    }, .{
        .@"example.zig" = 
        \\pub fn main() void {
        \\    std.log.info("Hello, ", .{});
        \\}
        ,

        .@"example2.zig" = 
        \\pub fn main() void {
        \\    std.log.info("world!", .{});
        \\}
        ,
    });
}

test "run multiple inputs" {
    try testCompareOutput(testing.allocator, &.{
        \\    lang: zig esc: <<>> file: example.zig
        \\    -------------------------------------
        \\
        \\    pub fn main() void {
        \\        <<example>>
        \\    }
        ,
        \\    lang: zig esc: none tag: #example
        \\    ---------------------------------
        \\
        \\    std.log.info("Hello, world!", .{});
    }, .{
        .@"example.zig" = 
        \\pub fn main() void {
        \\    std.log.info("Hello, world!", .{});
        \\}
        ,
    });
}
