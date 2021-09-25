const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;

const Tokenizer = @This();

bytes: []const u8,
index: usize = 0,

pub const Location = struct {
    line: usize = 1,
    column: usize = 1,
};

const log = std.log.scoped(.tokenizer);

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub const Tag = enum(u8) {
        eof,

        nl = '\n',
        space = ' ',

        word,
        line = '-',
        hash = '#',
        pipe = '|',
        colon = ':',

        l_angle = '<',
        l_brace = '{',
        l_bracket = '[',
        l_paren = '(',

        r_angle = '>',
        r_brace = '}',
        r_bracket = ']',
        r_paren = ')',

        unknown,
    };

    pub fn slice(t: Token, bytes: []const u8) []const u8 {
        return bytes[t.start..t.end];
    }

    pub fn len(t: Token) usize {
        return t.end - t.start;
    }
};

pub fn locationFrom(self: Tokenizer, from: Location) Location {
    assert(from.line != 0);
    assert(from.column != 0);

    var loc = from;
    const start = from.line * from.column - 1;

    for (self.bytes[start..self.index]) |byte| {
        if (byte == '\n') {
            loc.line += 1;
            loc.column = 1;
        } else {
            loc.column += 1;
        }
    }

    return loc;
}

pub fn next(self: *Tokenizer) Token {
    var token: Token = .{
        .tag = .eof,
        .start = self.index,
        .end = undefined,
    };

    defer log.debug("{s: >10} {d: >3} | {s}", .{
        @tagName(token.tag),
        token.len(),
        token.slice(self.bytes),
    });

    const State = enum { start, trivial, unknown, word };
    var state: State = .start;
    var trivial: u8 = 0;

    while (self.index < self.bytes.len) : (self.index += 1) {
        const c = self.bytes[self.index];
        switch (state) {
            .trivial => if (c != trivial) break,
            .start => switch (c) {
                ' ', '\n' => {
                    token.tag = @intToEnum(Token.Tag, c);
                    trivial = c;
                    state = .trivial;
                },
                '-' => {
                    token.tag = .line;
                    trivial = '-';
                    state = .trivial;
                },

                'a'...'z' => {
                    token.tag = .word;
                    state = .word;
                },

                '#', ':' => {
                    token.tag = @intToEnum(Token.Tag, c);
                    self.index += 1;
                    break;
                },
                '<', '{', '[', '(', ')', ']', '}', '>' => {
                    token.tag = @intToEnum(Token.Tag, c);
                    trivial = c;
                    state = .trivial;
                },
                '|' => {
                    token.tag = .pipe;
                    self.index += 1;
                    break;
                },
                else => {
                    token.tag = .unknown;
                    state = .unknown;
                },
            },

            .word => switch (c) {
                'a'...'z', 'A'...'Z', '#', '+', '-', '\'', '_' => {},
                else => break,
            },
            .unknown => if (mem.indexOfScalar(u8, "\n <{[()]}>:|", c)) |_| {
                break;
            },
        }
    }

    token.end = self.index;
    return token;
}

test "tokenize whitespace" {
    try testTokenize("\n", &.{.nl});
    try testTokenize(" ", &.{.space});
    try testTokenize("\n\n\n\n\n", &.{.nl});
    try testTokenize("\n\n     \n\n\n", &.{ .nl, .space, .nl });
}
test "tokenize header" {
    try testTokenize("-", &.{.line});
    try testTokenize("#", &.{.hash});
    try testTokenize(":", &.{.colon});
    try testTokenize("-----------------", &.{.line});
    try testTokenize("###", &.{ .hash, .hash, .hash });
    try testTokenize(":::", &.{ .colon, .colon, .colon });
}
test "tokenize include" {
    try testTokenize("|", &.{.pipe});
    try testTokenize("|||", &.{ .pipe, .pipe, .pipe });
}
test "tokenize unknown" {
    try testTokenize("/file.example/path/../__", &.{.unknown});
}
fn testTokenize(text: []const u8, expected: []const Token.Tag) !void {
    var it: Tokenizer = .{ .bytes = text };

    for (expected) |tag| {
        const token = it.next();
        try testing.expectEqual(tag, token.tag);
    }

    const token = it.next();
    try testing.expectEqual(Token.Tag.eof, token.tag);
    try testing.expectEqual(text.len, token.end);
}
