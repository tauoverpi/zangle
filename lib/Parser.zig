const std = @import("std");
const lib = @import("lib.zig");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;

const Tokenizer = lib.Tokenizer;
const Linker = lib.Linker;
const Allocator = std.mem.Allocator;
const Instruction = lib.Instruction;
const Parser = @This();

it: Tokenizer,
obj: Linker.Object,

const Token = Tokenizer.Token;
const log = std.log.scoped(.parser);

fn emitRet(
    p: *Parser,
    gpa: *Allocator,
) !void {
    log.debug("emitting ret", .{});
    try p.obj.program.append(gpa, .{
        .opcode = .ret,
        .data = .{ .ret = 0xffff_ffff },
    });
}
fn writeJmp(
    p: *Parser,
    location: u32,
    params: Instruction.Data.Jmp,
) !void {
    log.debug("writing jmp over {x:0>8} to {x:0>8}", .{
        location,
        params.address,
    });
    p.obj.program.set(location, .{
        .opcode = .jmp,
        .data = .{ .jmp = params },
    });
}
fn emitCall(
    p: *Parser,
    gpa: *Allocator,
    tag: []const u8,
    params: Instruction.Data.Call,
) !void {
    log.debug("emitting call to {s}", .{tag});
    const result = try p.obj.symbols.getOrPut(gpa, tag);
    if (!result.found_existing) {
        result.value_ptr.* = .{};
    }

    try result.value_ptr.append(gpa, @intCast(u32, p.obj.program.len));

    try p.obj.program.append(gpa, .{
        .opcode = .call,
        .data = .{ .call = params },
    });
}
fn emitShell(
    p: *Parser,
    gpa: *Allocator,
    params: Instruction.Data.Shell,
) !void {
    log.debug("emitting shell command", .{});
    try p.obj.program.append(gpa, .{
        .opcode = .shell,
        .data = .{ .shell = params },
    });
}
fn emitWrite(
    p: *Parser,
    gpa: *Allocator,
    params: Instruction.Data.Write,
) !void {
    log.debug("emitting write {x:0>8} len {d} nl {d}", .{
        params.start,
        params.len,
        params.nl,
    });
    try p.obj.program.append(gpa, .{
        .opcode = .write,
        .data = .{ .write = params },
    });
}

const Loc = std.builtin.SourceLocation;

pub fn eat(p: *Parser, tag: Token.Tag, loc: Loc) ?[]const u8 {
    const state = p.it;
    const token = p.it.next();
    if (token.tag == tag) {
        return token.slice(p.it.bytes);
    } else {
        log.debug("I'm starving for a '{s}' but this is a '{s}' ({s} {d}:{d})", .{
            @tagName(tag),
            @tagName(token.tag),
            loc.fn_name,
            loc.line,
            loc.column,
        });
        p.it = state;
        return null;
    }
}

pub fn next(p: *Parser) ?Token {
    const token = p.it.next();
    if (token.tag != .eof) {
        return token;
    } else {
        return null;
    }
}

pub fn scan(p: *Parser, tag: Token.Tag) ?Token {
    while (p.next()) |token| if (token.tag == tag) {
        return token;
    };

    return null;
}

pub fn expect(p: *Parser, tag: Token.Tag, loc: Loc) ?void {
    _ = p.eat(tag, loc) orelse {
        log.debug("Wanted a {s}, but got nothing captain ({s} {d}:{d})", .{
            @tagName(tag),
            loc.fn_name,
            loc.line,
            loc.column,
        });
        return null;
    };
}

pub fn slice(p: *Parser, from: usize, to: usize) []const u8 {
    assert(from <= to);
    return p.it.bytes[from..to];
}

pub fn match(p: *Parser, tag: Token.Tag, text: []const u8) ?void {
    const state = p.it;
    const token = p.it.next();
    if (token.tag == tag and mem.eql(u8, token.slice(p.it.bytes), text)) {
        return;
    } else {
        p.it = state;
        return null;
    }
}
const Header = struct {
    language: []const u8,
    delimiter: ?[]const u8,
    resource: []const u8,
    type: Type,

    pub const Type = enum { file, tag };
};

const ParseHeaderError = error {
    @"Expected a space between 'lang:' and the language name",
    @"Expected a space after the language name",
    @"Expected a space between 'esc:' and the delimiter specification",
    @"Expected open delimiter",
    @"Expected closing delimiter",
    @"Expected matching closing angle bracket '>'",
    @"Expected matching closing brace '}'",
    @"Expected matching closing bracket ']'",
    @"Expected matching closing paren ')'",
    @"Expected opening and closing delimiter lengths to match",
    @"Expected a space after delimiter specification",
    @"Expected 'tag:' or 'file:' following delimiter specification",
    @"Expected a space after 'file:'",
    @"Expected a space after 'tag:'",
    @"Expected a newline after the header",
    @"Expected the dividing line to be indented by 4 spaces",
    @"Expected a dividing line of '-' of the same length as the header",
    @"Expected the division line to be of the same length as the header",
    @"Expected at least one blank line after the division line",
    @"Expected there to be only one space but more were given",

    @"Missing language specification",
    @"Missing ':' after 'lang'",
    @"Missing language name",
    @"Missing 'esc:' delimiter specification",
    @"Missing ':' after 'esc'",
    @"Missing ':' after 'file'",
    @"Missing ':' after 'tag'",
    @"Missing '#' after 'tag: '",
    @"Missing file name",
    @"Missing tag name",

    @"Invalid delimiter, expected one of '<', '{', '[', '('",
    @"Invalid delimiter, expected one of '>', '}', ']', ')'",
    @"Invalid option given, expected 'tag:' or 'file:'",
};

fn parseHeaderLine(p: *Parser) ParseHeaderError!Header {
    var header: Header = undefined;

    const header_start = p.it.index;
    p.match(.word, "lang") orelse return error.@"Missing language specification";
    p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'lang'";

    if (p.eat(.space, @src())) |space| {
        if (space.len != 1) return error.@"Expected there to be only one space but more were given";
    } else {
        return error.@"Expected a space between 'lang:' and the language name";
    }

    header.language = p.eat(.word, @src()) orelse return error.@"Missing language name";
    p.expect(.space, @src()) orelse return error.@"Expected a space after the language name";
    p.match(.word, "esc") orelse return error.@"Missing 'esc:' delimiter specification";
    p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'esc'";

    if (p.eat(.space, @src())) |space| {
        if (space.len != 1) return error.@"Expected there to be only one space but more were given";
    } else {
        return error.@"Expected a space between 'esc:' and the delimiter specification";
    }

    if (p.match(.word, "none") == null) {
        const start = p.it.index;
        const open = p.next() orelse return error.@"Expected open delimiter";

        switch (open.tag) {
            .l_angle, .l_brace, .l_bracket, .l_paren => {},
            else => return error.@"Invalid delimiter, expected one of '<', '{', '[', '('",
        }

        const closed = p.next() orelse return error.@"Expected closing delimiter";
        switch (closed.tag) {
            .r_angle, .r_brace, .r_bracket, .r_paren => {},
            else => return error.@"Invalid delimiter, expected one of '>', '}', ']', ')'",
        }

        if (open.tag == .l_angle and closed.tag != .r_angle) {
            return error.@"Expected matching closing angle bracket '>'";
        } else if (open.tag == .l_brace and closed.tag != .r_brace) {
            return error.@"Expected matching closing brace '}'";
        } else if (open.tag == .l_bracket and closed.tag != .r_bracket) {
            return error.@"Expected matching closing bracket ']'";
        } else if (open.tag == .l_paren and closed.tag != .r_paren) {
            return error.@"Expected matching closing paren ')'";
        }

        if (open.len() != closed.len()) {
            return error.@"Expected opening and closing delimiter lengths to match";
        }

        header.delimiter = p.slice(start, p.it.index);
    } else {
        header.delimiter = null;
    }

    if (p.eat(.space, @src())) |space| {
        if (space.len != 1) return error.@"Expected there to be only one space but more were given";
    } else {
        return error.@"Expected a space after delimiter specification";
    }

    var start: usize = undefined;
    const tag = p.eat(.word, @src()) orelse {
        return error.@"Expected 'tag:' or 'file:' following delimiter specification";
    };

    if (mem.eql(u8, tag, "file")) {
        p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'file'";

        if (p.eat(.space, @src())) |space| {
            if (space.len != 1) return error.@"Expected there to be only one space but more were given";
        } else return error.@"Expected a space after 'file:'";

        header.type = .file;
        start = p.it.index;
    } else if (mem.eql(u8, tag, "tag")) {
        p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'tag'";

        if (p.eat(.space, @src())) |space| {
            if (space.len != 1) return error.@"Expected there to be only one space but more were given";
        } else return error.@"Expected a space after 'tag:'";

        p.expect(.hash, @src()) orelse return error.@"Missing '#' after 'tag: '";
        header.type = .tag;
        start = p.it.index;
    } else {
        return error.@"Invalid option given, expected 'tag:' or 'file:'";
    }

    const nl = p.scan(.nl) orelse {
        return error.@"Expected a newline after the header";
    };

    header.resource = p.slice(start, nl.start);
    if (header.resource.len == 0) {
        switch (header.type) {
            .file => return error.@"Missing file name",
            .tag => return error.@"Missing tag name",
        }
    }

    const len = (p.it.index - 1) - header_start;

    if ((p.eat(.space, @src()) orelse "").len != 4) {
        return error.@"Expected the dividing line to be indented by 4 spaces";
    }

    const line = p.eat(.line, @src()) orelse {
        return error.@"Expected a dividing line of '-' of the same length as the header";
    };

    if (line.len != len) {
        log.debug("header {d} line {d}", .{ len, line.len });
        return error.@"Expected the division line to be of the same length as the header";
    }

    if ((p.eat(.nl, @src()) orelse "").len < 2) {
        return error.@"Expected at least one blank line after the division line";
    }

    return header;
}

test "parse header line" {
    const common: Header = .{
        .language = "zig",
        .delimiter = "{{}}",
        .resource = "hash",
        .type = .tag,
    };

    try testing.expectError(
        error.@"Expected a space between 'lang:' and the language name",
        testParseHeader("lang:zig", common),
    );

    try testing.expectError(
        error.@"Missing 'esc:' delimiter specification",
        testParseHeader("lang: zig ", common),
    );

    try testing.expectError(
        error.@"Missing ':' after 'esc'",
        testParseHeader("lang: zig esc", common),
    );

    try testing.expectError(
        error.@"Expected a space between 'esc:' and the delimiter specification",
        testParseHeader("lang: zig esc:", common),
    );

    try testing.expectError(
        error.@"Expected closing delimiter",
        testParseHeader("lang: zig esc: {", common),
    );

    try testing.expectError(
        error.@"Expected matching closing angle bracket '>'",
        testParseHeader("lang: zig esc: <}", common),
    );

    try testing.expectError(
        error.@"Expected matching closing brace '}'",
        testParseHeader("lang: zig esc: {>", common),
    );

    try testing.expectError(
        error.@"Expected matching closing bracket ']'",
        testParseHeader("lang: zig esc: [>", common),
    );

    try testing.expectError(
        error.@"Expected matching closing paren ')'",
        testParseHeader("lang: zig esc: (>", common),
    );

    try testing.expectError(
        error.@"Invalid delimiter, expected one of '<', '{', '[', '('",
        testParseHeader("lang: zig esc: foo", common),
    );

    try testing.expectError(
        error.@"Invalid delimiter, expected one of '>', '}', ']', ')'",
        testParseHeader("lang: zig esc: <oo", common),
    );

    try testing.expectError(
        error.@"Expected opening and closing delimiter lengths to match",
        testParseHeader("lang: zig esc: {}}", common),
    );

    try testing.expectError(
        error.@"Expected a space after delimiter specification",
        testParseHeader("lang: zig esc: {{}}", common),
    );

    try testing.expectError(
        error.@"Expected 'tag:' or 'file:' following delimiter specification",
        testParseHeader("lang: zig esc: {{}} ", common),
    );

    try testing.expectError(
        error.@"Invalid option given, expected 'tag:' or 'file:'",
        testParseHeader("lang: zig esc: {{}} none", common),
    );

    try testing.expectError(
        error.@"Missing ':' after 'file'",
        testParseHeader("lang: zig esc: {{}} file", common),
    );

    try testing.expectError(
        error.@"Expected a space after 'file:'",
        testParseHeader("lang: zig esc: {{}} file:", common),
    );

    try testing.expectError(
        error.@"Missing file name",
        testParseHeader("lang: zig esc: {{}} file: \n", common),
    );

    try testing.expectError(
        error.@"Missing ':' after 'tag'",
        testParseHeader("lang: zig esc: {{}} tag", common),
    );

    try testing.expectError(
        error.@"Expected a space after 'tag:'",
        testParseHeader("lang: zig esc: {{}} tag:", common),
    );

    try testing.expectError(
        error.@"Missing '#' after 'tag: '",
        testParseHeader("lang: zig esc: {{}} tag: ", common),
    );

    try testing.expectError(
        error.@"Expected a newline after the header",
        testParseHeader("lang: zig esc: {{}} tag: #", common),
    );

    try testing.expectError(
        error.@"Missing tag name",
        testParseHeader("lang: zig esc: {{}} tag: #\n", common),
    );

    try testing.expectError(
        error.@"Expected the dividing line to be indented by 4 spaces",
        testParseHeader("lang: zig esc: {{}} tag: #hash\n", common),
    );

    try testing.expectError(
        error.@"Expected a dividing line of '-' of the same length as the header",
        testParseHeader("lang: zig esc: {{}} tag: #hash\n    ", common),
    );

    try testing.expectError(
        error.@"Expected the division line to be of the same length as the header",
        testParseHeader("lang: zig esc: {{}} tag: #hash\n    ----------------", common),
    );

    try testing.expectError(
        error.@"Expected at least one blank line after the division line",
        testParseHeader("lang: zig esc: {{}} tag: #hash\n    ------------------------------", common),
    );

    try testing.expectError(
        error.@"Expected at least one blank line after the division line",
        testParseHeader("lang: zig esc: {{}} tag: #hash\n    ------------------------------\n", common),
    );

    try testParseHeader("lang: zig esc: {{}} tag: #hash\n    ------------------------------\n\n", common);
}

fn testParseHeader(text: []const u8, expected: Header) !void {
    var p: Parser = .{ .it = .{ .bytes = text }, .obj = .{ .text = text } };
    const header = try p.parseHeaderLine();

    testing.expectEqualStrings(expected.language, header.language) catch return error.@"Language is not the same";

    if (expected.delimiter != null and header.delimiter != null) {
        testing.expectEqualStrings(expected.language, header.language) catch return error.@"Delimiter is not the same";
    } else if (expected.delimiter == null and header.delimiter != null) {
        return error.@"Expected delimiter to be null";
    } else if (expected.delimiter != null and header.delimiter == null) {
        return error.@"Expected delimiter to not be null";
    }

    testing.expectEqualStrings(expected.resource, header.resource) catch return error.@"Resource is not the same";
    testing.expectEqual(expected.type, header.type) catch return error.@"Type is not the same";
}
fn parseBody(p: *Parser, gpa: *Allocator, header: Header) !void {
    log.debug("begin parsing body", .{});
    defer log.debug("end parsing body", .{});

    const entry_point = @intCast(u32, p.obj.program.len);

    var nl: usize = 0;
    while (p.eat(.space, @src())) |space| {
        if (space.len < 4) break;
        nl = 0;

        var sol = p.it.index - (space.len - 4);
        while (p.next()) |token| switch (token.tag) {
            .nl => {
                nl = token.len();

                try p.emitWrite(gpa, .{
                    .start = @intCast(u32, sol),
                    .len = @intCast(u16, token.start - sol),
                    .nl = @intCast(u16, nl),
                });
                break;
            },

            .l_angle,
            .l_brace,
            .l_bracket,
            .l_paren,
            => if (header.delimiter) |delim| {
                if (delim[0] != @enumToInt(token.tag)) {
                    log.debug("dilimiter doesn't match, skipping", .{});
                    continue;
                }

                if (delim.len != token.len() * 2) {
                    log.debug("dilimiter length doesn't match, skipping", .{});
                    continue;
                }

                if (token.start - sol < 0) {
                    try p.emitWrite(gpa, .{
                        .start = @intCast(u32, sol),
                        .len = @intCast(u16, token.start - sol),
                        .nl = 0,
                    });
                }

                try p.parseDelimiter(gpa, delim, token.start - sol);
                sol = p.it.index;
            },

            else => {},
        };
    }

    const len = p.obj.program.len;
    if (len != 0) {
        const item = &p.obj.program.items(.data)[len - 1].write;
        item.nl = 0;
        if (item.len == 0) p.obj.program.len -= 1;
    }

    if (nl < 2) {
        return error.@"Expected a blank line after the end of the code block";
    }

    switch (header.type) {
        .tag => {
            const adj = try p.obj.adjacent.getOrPut(gpa, header.resource);
            if (adj.found_existing) {
                try p.writeJmp(adj.value_ptr.exit, .{
                    .address = entry_point,
                    .module = 0,
                });
            } else {
                adj.value_ptr.entry = entry_point;
            }

            adj.value_ptr.exit = @intCast(u32, p.obj.program.len);
        },

        .file => {
            const file = try p.obj.files.getOrPut(gpa, header.resource);
            if (file.found_existing) return error.@"Multiple file outputs with the same name";
            file.value_ptr.* = entry_point;
        },
    }

    try p.emitRet(gpa);
}
fn parseDelimiter(
    p: *Parser,
    gpa: *Allocator,
    delim: []const u8,
    indent: usize,
) !void {
    log.debug("parsing call", .{});

    var pipe = false;
    var colon = false;
    var reached_end = false;

    const tag = blk: {
        const start = p.it.index;
        while (p.next()) |sub| switch (sub.tag) {
            .nl => return error.@"Unexpected newline",
            .pipe => {
                pipe = true;
                break :blk p.it.bytes[start..sub.start];
            },
            .colon => {
                colon = true;
                break :blk p.it.bytes[start..sub.start];
            },

            .r_angle,
            .r_brace,
            .r_bracket,
            .r_paren,
            => if (@enumToInt(sub.tag) == delim[delim.len - 1]) {
                if (delim.len != sub.len() * 2) {
                    return error.@"Expected a closing delimiter of equal length";
                }
                reached_end = true;
                break :blk p.it.bytes[start..sub.start];
            },

            else => {},
        };

        return error.@"Unexpected end of file";
    };
    if (colon) {
        const ty = p.eat(.word, @src()) orelse return error.@"Missing 'from' following ':'";
        if (!mem.eql(u8, ty, "from")) return error.@"Unknown type operation";
        p.expect(.l_paren, @src()) orelse return error.@"Expected '(' following 'from'";
        p.expect(.word, @src()) orelse return error.@"Expected type name";
        p.expect(.r_paren, @src()) orelse return error.@"Expected ')' following type name";
    }
    if (pipe or p.eat(.pipe, @src()) != null) {
        const index = @intCast(u32, p.it.index);
        const shell = p.eat(.word, @src()) orelse {
            return error.@"Missing command following '|'";
        };

        if (shell.len > 255) return error.@"Shell command name too long";
        try p.emitShell(gpa, .{
            .command = index,
            .module = 0xffff,
            .len = @intCast(u8, shell.len),
            .pad = 0,
        });
    }

    try p.emitCall(gpa, tag, .{
        .address = undefined,
        .module = undefined,
        .indent = @intCast(u16, indent),
    });

    if (!reached_end) {
        const last = p.next() orelse return error.@"Expected closing delimiter";

        if (last.len() * 2 != delim.len) {
            return error.@"Expected closing delimiter length to match";
        }

        if (@enumToInt(last.tag) != delim[delim.len - 1]) {
            return error.@"Invalid closing delimiter";
        }
    }
}

pub fn parse(gpa: *Allocator, text: []const u8) !Linker.Object {
    var p: Parser = .{
        .it = .{ .bytes = text },
        .obj = .{ .text = text },
    };

    errdefer p.obj.deinit(gpa);

    var code_block = false;
    while (p.next()) |token| {
        if (token.tag == .nl and token.len() >= 2) {
            if (p.eat(.space, @src())) |space| if (space.len == 4 and !code_block) {
                const header = p.parseHeaderLine() catch |e| switch (e) {
                    error.@"Missing language specification" => {
                        code_block = true;
                        continue;
                    },
                    else => |err| return err,
                };

                try p.parseBody(gpa, header);
            } else if (space.len < 4) {
                code_block = false;
            };
        }
    }

    return p.obj;
}

test "parse body" {
    const text =
        \\    <<a b c:from(t)|f>>
        \\    [[a b c | : a}}
        \\    <<b|k>>
        \\    <<b:from(k)>>
        \\    <<<|:>>
        \\    <|:>
        \\
        \\text
    ;

    var p: Parser = .{ .it = .{ .bytes = text }, .obj = .{ .text = text } };
    defer p.obj.deinit(testing.allocator);
    try p.parseBody(testing.allocator, .{
        .language = "",
        .delimiter = "<<>>",
        .resource = "",
        .type = .tag,
    });
}

test "compile single tag" {
    const text =
        \\    <<a b c>>
        \\    <<. . .:from(zig)>>
        \\    <<1 2 3|com>>
        \\
        \\end
    ;

    var p: Parser = .{ .it = .{ .bytes = text }, .obj = .{ .text = text } };
    defer p.obj.deinit(testing.allocator);
    try p.parseBody(testing.allocator, .{
        .language = "",
        .delimiter = "<<>>",
        .resource = "foo",
        .type = .tag,
    });

    try testing.expect(p.obj.symbols.contains("a b c"));
    try testing.expect(p.obj.symbols.contains("1 2 3"));
    try testing.expect(p.obj.symbols.contains(". . ."));
}

const TestCompileResult = struct {
    program: []const Instruction.Opcode,
    symbols: []const []const u8,
    exports: []const []const u8,
};

fn testCompile(
    text: []const u8,
    result: TestCompileResult,
) !void {
    var obj = try Parser.parse(testing.allocator, text);
    defer obj.deinit(testing.allocator);

    errdefer for (obj.program.items(.opcode)) |op| {
        log.debug("{s}", .{@tagName(op)});
    };

    try testing.expectEqualSlices(
        Instruction.Opcode,
        result.program,
        obj.program.items(.opcode),
    );

    for (result.symbols) |sym| if (!obj.symbols.contains(sym)) {
        std.log.err("Missing symbol '{s}'", .{sym});
    };
}

test "compile block" {
    try testCompile(
        \\begin
        \\
        \\    lang: zig esc: <<>> tag: #here
        \\    ------------------------------
        \\
        \\    <<example>>
        \\
        \\end
    , .{
        .program = &.{ .call, .ret },
        .symbols = &.{"example"},
        .exports = &.{"here"},
    });
}

test "compile block with jump threadding" {
    try testCompile(
        \\begin
        \\
        \\    lang: zig esc: <<>> tag: #here
        \\    ------------------------------
        \\
        \\    <<example>>
        \\
        \\then
        \\
        \\    lang: zig esc: none tag: #here
        \\    ------------------------------
        \\
        \\    more
        \\
        \\end
    , .{
        .program = &.{ .call, .jmp, .write, .ret },
        .symbols = &.{"example"},
        .exports = &.{"here"},
    });
}

test "compile block multiple call" {
    try testCompile(
        \\begin
        \\
        \\    lang: zig esc: <<>> tag: #here
        \\    ------------------------------
        \\
        \\    <<one>>
        \\    <<two>>
        \\    <<three>>
        \\
        \\end
    , .{
        .program = &.{ .call, .write, .call, .write, .call, .ret },
        .symbols = &.{ "one", "two", "three" },
        .exports = &.{"here"},
    });
}

test "compile block inline" {
    try testCompile(
        \\begin
        \\
        \\    lang: zig esc: <<>> tag: #here
        \\    ------------------------------
        \\
        \\    <<one>><<two>>
        \\
        \\end
    , .{
        .program = &.{ .call, .call, .ret },
        .symbols = &.{ "one", "two" },
        .exports = &.{"here"},
    });
}
