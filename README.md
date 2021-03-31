---
title: Zangle
documentclass: article
geometry:
  - margin=0.6in
pagestyle: headings
links-as-notes: true
papersize: a4
...

# Abstract

Zangle is a tool and a library for extracting executable segments of code from
documentation into runnable source code while being compatible with [pandoc]
similar to [entangled].


# Configuration

Configuration can be given both on the command-line or via a configuration file
named `.zangle` residing within the current directory. The options are as follows:

| Option | Description | State |
| --     | --          | --    |
| `watch: bool = false,`{.zig #z-parameters} | Stay open and watch given files for changes. | incomplete |
| `config: ?[]const u8 = null,`{.zig #z-parameters} | Give the location of a configuration file to read. | incomplete |
| `doctest: bool = false,`{.zig #z-parameters} | Run code within test blocks. If this option is used along with `weave` then the expected result will also be printed. | incomplete |
| `weave: ?[]const u8 = null,`{.zig #z-parameters} | Generate a pretty version of the document for compilation to PDF with pandoc. | incomplete |
| `delimiter: Delimiter = .chevron,`{.zig #z-parameters} | Override the default placeholder delimites for all blocks. (see @tbl:configuration-delimiters}) | incomplete |

: Configuration parameters {#tbl:configuration-parameters}

| Style     |                                                          |
| --        | --                                                       |
| `ignore`  | None, delimiters are ignored and treated as regular text.|
| `chevron` | `<< >>`                                                  |
| `brace`   | `{{ }}`                                                  |

: Delimiters {#tbl:configuration-delimiters}

# Implementation (move this to it's own file to display merges?)

## Configuration file parsing

`zig-args` allows three different forms for specifying both true and false thus
it's replicated here such that the configuration file doesn't differ from
command-line arguments.

```{.zig #configuration-booleans}
const boolean = ComptimeStringMap(bool, .{
    .{ "yes", true },
    .{ "true", true },
    .{ "y", true },
    .{ "no", false },
    .{ "false", false },
    .{ "n", false },
});
```

```{.zig file="src/config.zig"}
const std = @import("std");
const testing = std.testing;
const meta = std.meta;
const mem = std.mem;
const ComptimeStringMap = std.ComptimeStringMap;

const lib = @import("lib");
const Tokenizer = lib.Tokenizer;
const Token = Tokenizer.Token;

const Iterator = struct {
    token: Tokenizer,
    index: usize = 0,
    failed: ?Token = null,

    pub const Pair = struct {
        key: []const u8,
        value: []const u8,
    };

    fn oneOf(it: *Iterator, expected: []const Token.Tag) !Token {
        const found = it.token.next();
        for (expected) |tag| {
            if (found.tag == tag) {
                return found;
            } else {
                it.failed = found;
            }
        }
        return error.UnexpectedToken;
    }

    fn expect(it: *Iterator, expected: Token.Tag) !void {
        _ = try it.oneOf(&.{expected});
    }

    pub fn next(it: *Iterator) !?Pair {
        const key: Token = found: {
            while (true) {
                const token = it.token.next();
                switch (token.tag) {
                    .identifier => break :found token,

                    .hash => while (true) {
                        switch (it.token.next().tag) {
                            .newline => break,
                            .eof => return null,
                            else => {},
                        }
                    },

                    .eof => return null,

                    else => {
                        it.failed = token;
                        return error.ExpectedKey;
                    },
                }
            }
        };

        try it.expect(.space);
        try it.expect(.equal);
        try it.expect(.space);

        var value = try it.oneOf(&.{ .identifier, .string });
        if (value.tag == .string) {
            value.data.start += 1;
            value.data.end -= 1;
        }

        const eol = it.token.next();
        switch (eol.tag) {
            .newline => {},
            .eof => {},
            else => {
                it.failed = eol;
                return error.UnexpectedLineTerminator;
            },
        }

        return Pair{
            .key = it.token.text[key.data.start..key.data.end],
            .value = it.token.text[value.data.start..value.data.end],
        };
    }
};

<<configuration-booleans>>

pub fn parse(comptime T: type, text: []const u8) !T {
    const fields = meta.fields(T);

    var result: T = undefined;
    var it = Iterator{ .token = Tokenizer{ .text = text } };
    var seen = [_]bool{false} ** fields.len;

    while (true) {
        const pair = (try it.next()) orelse break;
        var err: ?anyerror = null;

        inline for (fields) |field, i| {
            if (mem.eql(u8, field.name, pair.key)) {
                if (seen[i]) return error.DuplicateKeys;
                seen[i] = true;

                const bound = switch (@typeInfo(field.field_type)) {
                    .Bool => boolean.get(pair.value),
                    .Int => std.fmt.parseInt(field.field_type, pair.value, 0),
                    .Pointer => if (field.field_type == []const u8) @as(?[]const u8, pair.value) else {
                        @compileError(@typeName(field.field_type) ++
                           " is not allowed as a slice, only slice allowed is []const u8");
                    },
                    else => @compileError(@typeName(field.field_type) ++
                        " is not implemented"),
                };

                if (bound) |value| {
                    @field(result, field.name) = value;
                } else err = error.ExpectedValue;
            }
        }
    }

    inline for (fields) |field, i| if (!seen[i]) {
        if (field.default_value) |default| {
            @field(result, field.name) = default;
        } else return error.MissingValue;
    };

    return result;
}

test "parse application config spec" {
    const Spec = struct {
        watch: bool = false,
        doctest: bool = false,
        title: []const u8,
    };

    const config =
        \\# comment
        \\watch = true
        \\doctest = true
        \\title = "example title for the file"
    ;

    const result = try parse(Spec, config);

    testing.expectEqual(true, result.watch);
    testing.expectEqual(true, result.watch);
    testing.expectEqualStrings("example title for the file", result.title);
}
```


```{.zig file="src/main.zig"}
const std = @import("std");
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;

const lib = @import("lib");
const Delimiter = lib.Parser.Delimiter;

const config = @import("config.zig");

const args = @import("args");

test {
    testing.refAllDecls(config);
}

const gpa = std.heap.page_allocator;

const Spec = struct {
    <<z-parameters>>
};

pub fn main() !void {
    const options = try args.parseForCurrentProcess(Spec, gpa);
    defer options.arena.deinit();
}
```

[pandoc]: pandoc.org
[entangled]: https://entangled.github.io/
