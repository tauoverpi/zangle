const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;
const log = std.log.scoped(.compiler);

const Allocator = std.mem.Allocator;
const Tokenizer = @import("Tokenizer.zig");
const Interpreter = @import("Interpreter.zig");
const Linker = @import("Linker.zig");
const Compiler = @This();

it: Tokenizer,
symbols: Linker.Object.SymbolMap = .{},
adjacent: Linker.Object.AdjacentMap = .{},
files: Linker.Object.FileMap = .{},
bytecode: ByteList = .{},
doctest: DocTestList = .{},

const ByteList = std.ArrayListUnmanaged(u8);
const DocTestList = std.ArrayListUnmanaged(Linker.Object.DocTest);

const Token = Tokenizer.Token;

//// PUBLIC ////

pub fn deinit(p: *Compiler, gpa: *Allocator) void {
    for (p.symbols.values()) |*symbol| {
        symbol.locations.deinit(gpa);
    }
    p.adjacent.deinit(gpa);
    p.symbols.deinit(gpa);
    p.files.deinit(gpa);
    p.bytecode.deinit(gpa);
    p.doctest.deinit(gpa);
}

pub fn parseAndCompile(gpa: *Allocator, text: []const u8) !Linker.Object {
    var p: Compiler = .{ .it = .{ .bytes = text } };
    errdefer p.deinit(gpa);

    while (p.next()) |token| {
        switch (token.tag) {
            .nl => while (p.eat(.nl) != null) {} else continue,
            .space => if (token.len() == 4) {
                const header = try p.parseHeader();
                try p.parseAndCompileBlock(gpa, header);
            },
            else => _ = p.scan(.nl),
        }
    }

    return Linker.Object{
        .symbols = p.symbols,
        .adjacent = p.adjacent,
        .files = p.files,
        .bytecode = p.bytecode.toOwnedSlice(gpa),
        .text = text,
        .doctest = p.doctest.toOwnedSlice(gpa),
    };
}

test "compile example file" {
    var obj = try parseAndCompile(testing.allocator,
        \\This is an example of how lit works.
        \\
        \\    lang: code example
        \\    ------------------
        \\
        \\    This is a code sample that's not included in any output.
        \\
        \\However
        \\
        \\    lang: c esc: <> tag: #main
        \\    --------------------------
        \\
        \\    /* This code is! */
        \\    void main() { return 0; }
    );
    defer obj.deinit(testing.allocator);
}

test "compile with jmp threading" {
    var obj = try parseAndCompile(testing.allocator,
        \\    lang: txt esc: none tag: #example
        \\    ---------------------------------
        \\
        \\    A
        \\
        \\---
        \\
        \\    lang: txt esc: none tag: #example
        \\    ---------------------------------
        \\
        \\    B
    );
    defer obj.deinit(testing.allocator);

    const B = Interpreter.Bytecode;

    const program: []const u8 = &.{
        // zig fmt: off
        B.write.code(),
        0, 0, 0, 81,
        0, 1,

        B.jmp.code(),
        0, 0, 0, 14,
        0, 0,

        B.write.code(),
        0, 0, 0, 170,
        0, 1,

        B.ret.code(),
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff,
        // zig fmt: on
    };

    try testing.expectEqualSlices(u8, program, obj.bytecode);
}

//// INTERNAL ////

fn expect(p: *Compiler, tag: Token.Tag) !void {
    _ = p.eat(tag) orelse return error.@"tag not found";
}

fn scan(p: *Compiler, tag: Token.Tag) ?Token {
    while (p.next()) |token| if (token.tag == tag) {
        return token;
    };

    return null;
}

fn next(p: *Compiler) ?Token {
    const token = p.it.next();
    if (token.tag == .eof) {
        return null;
    } else {
        return token;
    }
}

fn eat(p: *Compiler, tag: Token.Tag) ?[]const u8 {
    const state = p.it;
    const token = p.it.next();
    if (token.tag == tag) {
        return token.slice(p.it.bytes);
    } else {
        p.it = state;
        return null;
    }
}

const Header = struct {
    lang: []const u8,
    esc: ?[]const u8 = null,
    file: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    scope: Linker.Object.Scope = .local,
    special: Special = .none,
};

const Special = union(enum) { none, example, doctest: []const u8 };

fn parseHeader(p: *Compiler) !Header {
    var desc: Header = .{ .lang = undefined };

    const header = p.it.index;

    log.debug("begin header", .{});
    p.expect(.lang) catch return error.@"Missing language";
    try p.expect(.space);
    desc.lang = p.eat(.word) orelse return error.@"Missing language name";

    try p.expect(.space);

    if (p.expect(.esc)) {
        try p.expect(.space);

        const esc_start = p.it.index;
        if (p.eat(.word)) |word| {
            if (!mem.eql(u8, word, "none")) return error.@"Expecting a valid delimiter or `none`";
        } else {
            const open = p.next() orelse return error.@"Expected open delimiter";
            const close = p.next() orelse return error.@"Expected closing delimiter";

            switch (open.tag) {
                .l_brace => if (close.tag != .r_brace) return error.@"Expected matching closing brace `}`",
                .l_paren => if (close.tag != .r_paren) return error.@"Expected matching closing paren `)`",
                .l_angle => if (close.tag != .r_angle) return error.@"Expected matching closing angle bracket `>`",
                .l_bracket => if (close.tag != .r_bracket) return error.@"Expected matching closing bracket `]`",
                else => return error.@"Invalid delimiter, expected one of `{`, `(`, `<`, `[`",
            }

            desc.esc = p.it.bytes[esc_start..p.it.index];
        }

        try p.expect(.space);

        const tagfile = p.next() orelse return error.@"Missing attribute, valid attributes are `tag:` and `file:`";
        try p.expect(.space);

        const tag_start = p.it.index;
        switch (tagfile.tag) {
            .file => {
                const endl = p.scan(.nl) orelse return error.@"Expected a new line following filename";
                desc.file = p.it.bytes[tag_start..endl.start];
            },
            .tag => {
                if (mem.eql(u8, tagfile.slice(p.it.bytes), "global")) desc.scope = .global;
                p.expect(.hash) catch return error.@"Invalid tag name";
                _ = p.scan(.nl) orelse return error.@"Expected a new line following hash '#'";

                desc.tag = p.it.bytes[tag_start + 1 .. p.it.index - 1];

                if (mem.indexOfAny(u8, desc.tag.?, "<>{}[]():|") != null) {
                    return error.@"Disallowed characters within block tag name";
                }
            },

            .doctest => {
                const endl = p.scan(.nl) orelse return error.@"Expected a new line following `doctest`";
                desc.special = .{ .doctest = p.it.bytes[tag_start..endl.start] };
            },
            else => return error.@"Expected either `tag:` or `file:`",
        }
    } else |_| {
        const skip = p.eat(.word) orelse return error.@"Expected either `example` or `esc:`";
        if (!mem.eql(u8, skip, "example")) return error.@"Invalid";
        p.expect(.nl) catch return error.@"Expected a new line after `example`";
    }

    log.debug("end header", .{});
    const len = (p.it.index - header) - 1;

    if (p.eat(.space)) |indent| if (indent.len != 4) return error.@"Division line must be indented 4 spaces";

    const line = p.eat(.line) orelse return error.@"Division line can only consist of `-`";
    if (len > line.len) return error.@"Division line is shorter than the code block specification";
    if (len < line.len) return error.@"Division line is longer than the code block specification";
    p.expect(.nl) catch return error.@"Expected a new line following the division line";
    p.expect(.nl) catch return error.@"Expected an empty line between the divider and code";
    return desc;
}

test "parse file header" {
    var it: Compiler = .{ .it = .{ .bytes = 
    \\    lang: zig esc: {} file: foo.txt
    \\    -------------------------------
    \\
    \\
    } };

    try it.expect(.space);
    const header = try it.parseHeader();
    try testing.expectEqualStrings("zig", header.lang);
    try testing.expectEqualStrings("{}", header.esc orelse return error.@"failed to parse esc");
    try testing.expectEqualStrings("foo.txt", header.file orelse return error.@"failed to parse filename");
    try testing.expectEqual(@as(?[]const u8, null), header.tag);
}

test "parse tag header" {
    var it: Compiler = .{ .it = .{ .bytes = 
    \\    lang: c# esc: {} tag: #txt
    \\    --------------------------
    \\
    \\
    } };

    try it.expect(.space);
    const header = try it.parseHeader();
    try testing.expectEqualStrings("c#", header.lang);
    try testing.expectEqualStrings("{}", header.esc orelse return error.@"failed to parse esc");
    try testing.expectEqual(@as(?[]const u8, null), header.file);
    try testing.expectEqualStrings("txt", header.tag orelse return error.@"failed to parse tag");
}

test "parse example header" {
    var it: Compiler = .{ .it = .{ .bytes = 
    \\    lang: c++ example
    \\    -----------------
    \\
    \\
    } };

    try it.expect(.space);
    const header = try it.parseHeader();
    try testing.expectEqualStrings("c++", header.lang);
    try testing.expectEqual(@as(?[]const u8, null), header.file);
    try testing.expectEqual(@as(?[]const u8, null), header.tag);
    try testing.expectEqual(@as(?[]const u8, null), header.esc);
}

fn Emit(comptime kind: Interpreter.Bytecode) type {
    return switch (kind) {
        .ret => void,
        .write_nl => u8,
        .write => struct { ptr: u32, len: u16 },
        .call => struct { label: []const u8, indentation: u16, scope: Linker.Object.Scope },
        .shell => struct { label: []const u8, indentation: u16, command: u32, scope: Linker.Object.Scope },
        .jmp => @compileError("jmp should only ever be patched!"),
        else => @compileError("invalid instruction"),
    };
}

fn emit(p: *Compiler, gpa: *Allocator, comptime kind: Interpreter.Bytecode, value: Emit(kind)) error{OutOfMemory}!void {
    switch (kind) {
        .ret => {
            log.debug("emitting {s}", .{@tagName(kind)});

            // reserve enough space to patch a jmp instruction
            try p.bytecode.appendSlice(gpa, &.{
                kind.code(),
                0xff, 0xff, 0xff, 0xff, // unused offset
                0xff, 0xff, // unused module
            });
        },

        .call => {
            log.debug("emitting {s}", .{@tagName(kind)});

            try p.bytecode.append(gpa, @enumToInt(kind));

            if (true or value.scope == .global) {
                const entry = try p.symbols.getOrPut(gpa, value.label);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{};
                }
                log.debug("call to `{s}' from {d}", .{ value.label, p.bytecode.items.len });
                try entry.value_ptr.locations.append(gpa, @intCast(u32, p.bytecode.items.len));
            }

            try p.bytecode.appendSlice(gpa, &.{
                0xff, 0xff, 0xff, 0xff, // procedure
                0xff, 0xff, // module
            });

            const indentation = mem.nativeToBig(u16, value.indentation);
            try p.bytecode.appendSlice(gpa, mem.asBytes(&indentation));
        },

        .write_nl => {
            log.debug("emitting {s}", .{@tagName(kind)});

            try p.bytecode.append(gpa, @enumToInt(kind));
            try p.bytecode.append(gpa, value);
        },

        .write => {
            log.debug("emitting {s}", .{@tagName(kind)});

            const ptr = mem.nativeToBig(u32, value.ptr);
            const len = mem.nativeToBig(u16, value.len);

            try p.bytecode.append(gpa, @enumToInt(kind));
            try p.bytecode.appendSlice(gpa, mem.asBytes(&ptr));
            try p.bytecode.appendSlice(gpa, mem.asBytes(&len));
        },

        .shell => {
            log.debug("emitting {s}", .{@tagName(kind)});

            try p.bytecode.append(gpa, @enumToInt(kind));

            if (true or value.scope == .global) {
                const entry = try p.symbols.getOrPut(gpa, value.label);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                try entry.value_ptr.locations.append(gpa, @intCast(u32, p.bytecode.items.len));
            }

            const command = mem.nativeToBig(u32, value.command);
            try p.bytecode.appendSlice(gpa, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
            const indentation = mem.nativeToBig(u16, value.indentation);
            try p.bytecode.appendSlice(gpa, mem.asBytes(&indentation));
            try p.bytecode.appendSlice(gpa, mem.asBytes(&command));
        },

        else => unreachable,
    }
}

fn parseAndCompileBlock(p: *Compiler, gpa: *Allocator, header: Header) !void {
    log.debug("begin code", .{});
    defer log.debug("end code", .{});

    const entry_point = @intCast(u32, p.bytecode.items.len);
    const is_example_block = header.special == .example;
    var last_is_newline = false;
    var sol: usize = undefined;

    while (p.eat(.space)) |space| {
        if (space.len < 4) break;
        sol = p.it.index - (space.len - 4);
        last_is_newline = false;

        while (p.next()) |token| switch (token.tag) {
            .nl => {
                const len = (p.it.index - sol) - 1;
                if (!is_example_block and len >= 1) {
                    try p.emit(gpa, .write, .{ .ptr = @intCast(u32, sol), .len = @intCast(u16, len) });
                }
                var nl: u32 = 1;
                while (p.eat(.nl)) |_| : (nl += 1) {}
                if (!is_example_block) {
                    last_is_newline = true;
                    try p.emit(gpa, .write_nl, @intCast(u8, nl));
                }
                break;
            },

            .l_paren, .l_brace, .l_angle, .l_bracket => if (!is_example_block and header.esc != null) {
                const esc = header.esc.?;
                const len = token.len();

                if (len != esc.len / 2) continue;
                if (!mem.eql(u8, token.slice(p.it.bytes), esc[0..token.len()])) continue;

                const indentation = @intCast(u16, p.it.index - sol) - 2;
                if (indentation > 0) {
                    try p.emit(gpa, .write, .{
                        .ptr = @intCast(u32, p.it.index) - (indentation + 2),
                        .len = indentation,
                    });
                }

                log.debug("begin tag", .{});
                defer log.debug("end tag", .{});
                defer sol = p.it.index;

                var colon = false;
                var pipe = false;
                var last_token: ?Token = null;

                const start_ident = p.it.index;
                const end_ident = while (p.next()) |tok| {
                    switch (tok.tag) {
                        .nl => return error.@"Missing closing tag",
                        .colon => colon = true,
                        .pipe => pipe = true,
                        .r_paren, .r_brace, .r_angle, .r_bracket => last_token = tok,
                        else => continue,
                    }
                    break tok.start;
                } else return error.@"Missing closing delimiter";

                const ident = p.it.bytes[start_ident..end_ident];

                if (colon) {
                    var typ = p.eat(.word) orelse return error.@"Expected block type";
                    if (mem.eql(u8, typ, "from")) {
                        p.expect(.l_paren) catch return error.@"Missing '(' in type cast";
                        typ = p.eat(.word) orelse return error.@"Expected block type in `from` cast";
                        p.expect(.r_paren) catch return error.@"Missing ')' in type cast";
                    }
                }

                if (pipe or p.eat(.pipe) != null) {
                    var index = p.it.index;
                    _ = p.eat(.word) orelse return error.@"Expected a command following `|`";

                    try p.emit(gpa, .shell, .{
                        .label = ident,
                        .command = @intCast(u23, index),
                        .indentation = indentation,
                        .scope = header.scope,
                    });
                } else {
                    try p.emit(gpa, .call, .{
                        .label = ident,
                        .indentation = indentation,
                        .scope = header.scope,
                    });
                }

                const end = last_token orelse p.next() orelse return error.@"Missing closing delimiter";
                switch (end.tag) {
                    .r_paren,
                    .r_brace,
                    .r_angle,
                    .r_bracket,
                    => if (!mem.eql(u8, end.slice(p.it.bytes), esc[len .. len + len])) {
                        return error.@"Expected closing delimiter to match opening delimiter";
                    },
                    else => return error.@"Invalid closing delimiter",
                }
            },

            else => {},
        };
    }

    // remove the trailing newline
    if (last_is_newline) {
        p.bytecode.shrinkRetainingCapacity(p.bytecode.items.len - 2);
    } else if (!is_example_block) {
        const len = p.it.index - sol;
        if (len >= 1) {
            try p.emit(gpa, .write, .{ .ptr = @intCast(u32, sol), .len = @intCast(u16, len) });
        }
    }

    if (header.tag) |tag| {
        const tail = @intCast(u32, p.bytecode.items.len);
        try p.emit(gpa, .ret, {});

        const entry = try p.adjacent.getOrPut(gpa, tag);
        if (!entry.found_existing) {
            log.debug("new procedure `{s}' at 0x{x}", .{ tag, entry_point });
            entry.value_ptr.* = .{
                .module_entry = entry_point,
                .module_exit = tail,
                .scope = header.scope,
            };
        } else {
            const last_exit = entry.value_ptr.module_exit;
            log.debug("extending procedure with 0x{x}", .{entry_point});
            switch (entry.value_ptr.scope) {
                .local => if (header.scope != .local) return error.@"Scope declared as `global` in a local block group",
                .global => if (header.scope != .global) return error.@"Scope declared as `local` in a global block group",
            }

            // Block merge via threading by writing over the last `ret` instruction with `jmp`
            // and a local address.
            p.bytecode.items[last_exit] = Interpreter.Bytecode.jmp.code();
            assert(mem.readIntSliceNative(u32, p.bytecode.items[last_exit + 1 .. last_exit + 5]) == 0xffff_ffff);
            mem.writeIntSliceBig(u32, p.bytecode.items[last_exit + 1 .. last_exit + 5], entry_point);
            mem.writeIntSliceBig(u16, p.bytecode.items[last_exit + 5 .. last_exit + 7], 0);

            entry.value_ptr.module_exit = tail;
        }
    } else if (header.file) |tag| {
        if ((try p.files.fetchPut(gpa, tag, entry_point)) != null) {
            return error.@"Duplicate file block during compliation";
        }
        try p.emit(gpa, .ret, {});
    } else switch (header.special) {
        .doctest => |command| try p.doctest.append(gpa, .{
            .entry_point = entry_point,
            .command = command,
        }),
        else => {},
    }
}

test "codegen empty newline" {
    var p: Compiler = .{ .it = .{ .bytes = "    \n" } };
    defer p.deinit(testing.allocator);
    try p.parseAndCompileBlock(testing.allocator, .{
        .lang = "zig",
        .esc = "<<>>",
        .file = null,
        .tag = "test",
    });

    const B = Interpreter.Bytecode;

    try testing.expectEqualSlices(u8, &.{
        B.ret.code(),
        0xff, 0xff, 0xff, 0xff, // offset
        0xff, 0xff, // module
    }, p.bytecode.items);
}

test "codegen word newline newline word newline" {
    var p: Compiler = .{ .it = .{ .bytes = "    example\n\n    example\n" } };
    defer p.deinit(testing.allocator);
    try p.parseAndCompileBlock(testing.allocator, .{
        .lang = "zig",
        .esc = "<<>>",
        .file = null,
        .tag = "test",
    });

    const B = Interpreter.Bytecode;

    try testing.expectEqualSlices(u8, &.{
        // zig fmt: off
        B.write.code(),
        0, 0, 0, 4, // ptr
        0, 7, // len

        B.write_nl.code(),
        2, // len

        B.write.code(),
        0, 0, 0, 17, // ptr
        0, 7, // len

        B.ret.code(),
        0xff, 0xff, 0xff, 0xff, // offset
        0xff, 0xff, // module

        // zig fmt: on
    }, p.bytecode.items);
}

test "codegen include" {
    var p: Compiler = .{ .it = .{ .bytes = "    <<identifier>>\n" } };
    defer p.deinit(testing.allocator);
    try p.parseAndCompileBlock(testing.allocator, .{
        .lang = "zig",
        .esc = "<<>>",
        .file = null,
        .tag = "test",
    });

    const B = Interpreter.Bytecode;

    try testing.expectEqualSlices(u8, &.{
        // zig fmt: off
        B.call.code(),
        0xff, 0xff, 0xff, 0xff, // offset
        0xff, 0xff, 0, 0, // module

        B.ret.code(),
        0xff, 0xff, 0xff, 0xff, // offset
        0xff, 0xff, // module
        // zig fmt: on

    }, p.bytecode.items);
}

test "codegen include type" {
    var p: Compiler = .{ .it = .{ .bytes = "    <<identifier:type>>\n" } };
    defer p.deinit(testing.allocator);
    try p.parseAndCompileBlock(testing.allocator, .{
        .lang = "zig",
        .esc = "<<>>",
        .file = null,
        .tag = "test",
    });

    const B = Interpreter.Bytecode;

    try testing.expectEqualSlices(u8, &.{
        // zig fmt: off
        B.call.code(),
        0xff, 0xff, 0xff, 0xff, // offset
        0xff, 0xff, 0, 0, // module

        B.ret.code(),
        0xff, 0xff, 0xff, 0xff, // offset
        0xff, 0xff, // module
        // zig fmt: on
    }, p.bytecode.items);
}

test "codegen include pipe" {
    var p: Compiler = .{ .it = .{ .bytes = "    <<identifier|escape>>\n" } };
    defer p.deinit(testing.allocator);
    try p.parseAndCompileBlock(testing.allocator, .{
        .lang = "zig",
        .esc = "<<>>",
        .file = null,
        .tag = "test",
    });

    const B = Interpreter.Bytecode;

    try testing.expectEqualSlices(u8, &.{
        // zig fmt: off
        B.shell.code(),
        0xff, 0xff, 0xff, 0xff, // offset
        0xff, 0xff, // module
        0, 0, // indentation
        0, 0, 0, 17, // command

        B.ret.code(),
        0xff, 0xff, 0xff, 0xff, // offset
        0xff, 0xff, // module
        // zig fmt: on
    }, p.bytecode.items);
}

test "codegen include trail" {
    var p: Compiler = .{ .it = .{ .bytes = "    <<identifier>>example\n" } };
    defer p.deinit(testing.allocator);
    try p.parseAndCompileBlock(testing.allocator, .{
        .lang = "zig",
        .esc = "<<>>",
        .file = null,
        .tag = "test",
    });

    const B = Interpreter.Bytecode;

    try testing.expectEqualSlices(u8, &.{
        // zig fmt: off
        B.call.code(),
        0xff, 0xff, 0xff, 0xff, // offset
        0xff, 0xff, 0, 0, // module

        B.write.code(),
        0, 0, 0, 18, // ptr
        0, 7, // len

        B.ret.code(),
        0xff, 0xff, 0xff, 0xff, // offset
        0xff, 0xff, // module
        // zig fmt: on
    }, p.bytecode.items);
}
