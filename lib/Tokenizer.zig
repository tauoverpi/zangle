const std = @import("std");
const Tokenizer = @This();

bytes: []const u8,
index: usize = 0,

const log = std.log.scoped(.tokenizer);

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub const Tag = enum(u8) {
        eof,

        space,
        nl,
        lang,
        file,
        tag,
        esc,
        line,
        word,
        tagname,
        colon,
        pipe,
        l_brace = '{',
        l_paren = '(',
        l_angle = '<',
        l_bracket = '[',
        r_brace = '}',
        r_paren = ')',
        r_angle = '>',
        r_bracket = ']',
        unknown,
    };

    pub fn slice(t: Token, bytes: []const u8) []const u8 {
        return bytes[t.start..t.end];
    }

    pub fn len(t: Token) usize {
        return t.end - t.start;
    }
};

const State = enum {
    start,
    trivial,
    word,
    unknown,
    tagname_start,
    tagname,
};

const map = std.ComptimeStringMap(Token.Tag, .{
    // TODO: more options
    .{ "lang", .lang },
    .{ "file", .file },
    .{ "tag", .tag },
    .{ "esc", .esc },
});

pub fn next(it: *Tokenizer) Token {
    var token: Token = .{
        .tag = .eof,
        .start = it.index,
        .end = undefined,
    };

    var state: State = .start;
    var trivial: u8 = 0;

    defer {
        var slice = token.slice(it.bytes);
        if (token.tag == .nl) slice = token.slice(it.bytes)[0 .. token.len() - 1];
        log.debug("{s: <10} {s: >10} |{s}|", .{ @tagName(state), @tagName(token.tag), slice });
    }

    while (it.index < it.bytes.len) : (it.index += 1) {
        const c = it.bytes[it.index];

        switch (state) {
            .start => switch (c) {
                '\n' => {
                    token.tag = .nl;
                    it.index += 1;
                    break;
                },

                ' ' => {
                    token.tag = .space;
                    trivial = ' ';
                    state = .trivial;
                },

                ':' => {
                    token.tag = .colon;
                    it.index += 1;
                    break;
                },

                '|' => {
                    token.tag = .pipe;
                    it.index += 1;
                    break;
                },

                '{' => {
                    token.tag = .l_brace;
                    trivial = '{';
                    state = .trivial;
                },

                '(' => {
                    token.tag = .l_paren;
                    trivial = '(';
                    state = .trivial;
                },

                '[' => {
                    token.tag = .l_bracket;
                    trivial = '[';
                    state = .trivial;
                },

                '<' => {
                    token.tag = .l_angle;
                    trivial = '<';
                    state = .trivial;
                },

                '}' => {
                    token.tag = .r_brace;
                    trivial = '}';
                    state = .trivial;
                },

                ')' => {
                    token.tag = .r_paren;
                    trivial = ')';
                    state = .trivial;
                },

                ']' => {
                    token.tag = .r_bracket;
                    trivial = ']';
                    state = .trivial;
                },

                '>' => {
                    token.tag = .r_angle;
                    trivial = '>';
                    state = .trivial;
                },

                '-' => {
                    token.tag = .line;
                    trivial = '-';
                    state = .trivial;
                },

                '#' => {
                    token.tag = .unknown;
                    state = .tagname_start;
                },

                'a'...'z' => {
                    token.tag = .unknown;
                    state = .word;
                },

                else => state = .unknown,
            },

            .trivial => if (c != trivial) break,

            .word => switch (c) {
                'a'...'z', '#', '+', '-' => {},

                ' ', '\n', '{', '}', '<', '>', '(', ')', '[', ']', '|' => {
                    token.tag = .word;
                    break;
                },

                ':' => {
                    if (map.get(it.bytes[token.start..it.index])) |tag| {
                        token.tag = tag;
                        it.index += 1;
                    } else {
                        token.tag = .word;
                    }
                    break;
                },

                else => state = .unknown,
            },

            .tagname_start => switch (c) {
                'a'...'z' => {
                    token.tag = .tagname;
                    state = .tagname;
                },
                else => break,
            },

            .tagname => switch (c) {
                'a'...'z', '_' => {},
                else => break,
            },

            .unknown => switch (c) {
                '\n' => {
                    token.tag = .unknown;
                    break;
                },

                else => {},
            },
        }
    }

    token.end = it.index;
    return token;
}
