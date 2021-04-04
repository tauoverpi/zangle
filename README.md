![Zangle logo](assets/svg/zangle.svg?raw=true)

# Abstract

Zangle is a tool and a library for extracting executable segments of code from
documentation into runnable source code while being compatible with [pandoc]
similar to [entangled] with integration with the Zig build system.

TODO:

- [ ] weave - extract metadata (e.g title) from the YAML block and render it for github markdown
- [x] weave - remove constructs github markdown doesn't support (excluding things which don't clash with the format)
- [ ] weave - doctest rendering
- [ ] weave - handle blocks marked as `.inline`
- [ ] doctest - custom command runners
- [ ] doctest - expected output test
- [ ] remove this list once all entries have been resolved and switch to issues

## Introduction

TODO explain blocks

**main-imports**
```zig
const std = @import("std");
const testing = std.testing;

const lib = @import("lib");
const Delimiter = lib.Parser.Delimiter;

const config = @import("config.zig");
```

The module also makes sure to reference all definitions within locally
imported modules such as the configuration module through Zig's testing
module using `testing.refAllDecls(config)`.

**main**
```zig
<<copyright-comment>>

<<main-imports>>

test {
    <<main-test-case>>;
}

const Configuration = struct {
    <<cli-parameters>>
};

pub fn main() !void {
    // TODO
}
```

In this document the inline code block in the description above the `main` code
block is marked with ` {.zig #main-test-case}`
allowing the code within to be inlined anywhere using it's placeholder form
`<<main-test-case>>` which will inline without a trailing newline. The same
is used within the configuration parameters section in @tbl:configuration-parameters,
@tbl:configuration-shorthand, @tbl:configuration-delimiters, and in other places
ensure the document is kept in sync with the implementation.

TODO: render some visual aid such that it's possible to see that the inline
block is indeed related to the code below it. Maybe inline the text too with
the hint?


## Building

```
zig build
```
[pandoc]: pandoc.org
[entangled]: https://entangled.github.io/
# Configuration

Configuration can be given both on the command-line or via a configuration file
named `.zangle` residing within the current directory. The options are as follows:

| Option | Description | State |
| --     | --          | --    |
| `watch: bool = false,` | Stay open and watch given files for changes. | incomplete |
| `config: ?[]const u8 = null,` | Give the location of a configuration file to read. | incomplete |
| `doctest: bool = false,` | Run code within test blocks. If this option is used along with `weave` then the expected result will also be printed. | incomplete |
| `weave: ?[]const u8 = null,` | Generate a pretty version of the document for compilation to PDF with pandoc. | incomplete |
| `delimiter: Delimiter = .chevron,` | Override the default placeholder delimites for all blocks. (see @tbl:configuration-delimiters}) | incomplete |
| `entangle: bool = false,` | Enable entangled mode where changes in generated source files are written back to the document | incomplete |
| `file: []const []const u8,` | Specify a file to tangle | incomplete |

: Configuration parameters {#tbl:configuration-parameters}

| Style     |                                                          |
| --        | --                                                       |
| `ignore`  | None, delimiters are ignored and treated as regular text.|
| `chevron` | `<< >>`                                                  |
| `brace`   | `{{ }}`                                                  |

: Delimiters for code-block placeholders {#tbl:configuration-delimiters}


## Command-line arguments


**command-line-iterator**
```zig
pub fn CliIterator(comptime short: anytype, comptime long: anytype) type {
    return struct {
        args: []const []const u8,
        token: Tokenizer = undefined,
        failed: ?Token = null,
        state: State = .start,
        index: usize = 0,

        <<iterator-one-of>>

        <<iterator-expect>>

        pub const Arg = union(enum) {
            short: u8,
            long: []const u8,
            file: []const u8,
            pair: Pair,
        };


        const Self = @This();

        <<command-line-iterator-next>>

    };
}


pub const State = enum {
    start,
    filename,
};

const short_options = ComptimeStringMap(State, .{
    .{ "f", .filename },
    .{ "o", .filename },
});

const long_options = ComptimeStringMap(State, .{
    .{ "file", .filename },
    .{ "output", .filename },
});

```


**command-line-iterator-next**
```zig
pub fn next(it: *Self) !?Arg {
    it.token = Tokenizer{ .text = it.args[it.index] };
    it.index += 1;

    while (true) {
        switch (it.state) {
            .start => switch ((try it.oneOf(&.{.line_fence})).len()) {
                1 => {
                    const byte = try it.oneOf(&.{.identifier});
                    if (byte.len() != 1) return error.InvalidShortOption;

                    <<cli-iterator-redirection>>

                    return Arg{ .short = text[0] };
                },

                2 => {
                    const key = try it.oneOf(&.{.identifier});
                    switch (it.token.next().tag) {
                        .eof => {
                            const text = key.slice(it.token.text);
                            it.state = long.get(text) orelse .start;
                            return Arg{ .long = text };
                        },

                        .equal => {
                            return Arg{ .pair = .{
                                .key = key.slice(it.token.text),
                                .value = it.token.text[it.token.index..],
                            } };
                        },

                        else => return error.InvalidOption,
                    }
                },

                else => return error.InvalidOption,
            },

            .filename => {
                it.state = .start;
                return Arg{ .file = it.token.text };
            },
        }
    }
}
```


The parsing loop itself uses `ComptimeStringMap` to redirect flow to
handle arguments which take a parameter after the flag. The choice is to make
playing with different ways to express options easier.

**cli-iterator-redirection**
```zig
const text = byte.slice(it.token.text);
it.state = short.get(text) orelse .start;
```

**command-line-iterator**
```zig
test {
    var it = CliIterator(short_options, long_options){ .args = &.{
        "-f",
        "README.md",
        "--watch",
        "--output=file.md",
        "--tangle"
    } };

    testing.expectEqual(@as(u8, 'f'), (try it.next()).?.short);
    testing.expectEqualStrings("README.md", (try it.next()).?.file);
    testing.expectEqualStrings("watch", (try it.next()).?.long);
    testing.expectEqualStrings("file.md", (try it.next()).?.pair.value);
    testing.expectEqualStrings("tangle", (try it.next()).?.long);
}
```

## Configuration file parsing

**configuration-iterator**
```zig
const ConfigIterator = struct {
    token: Tokenizer,
    failed: ?Token = null,

    <<iterator-one-of>>

    <<iterator-expect>>

    <<iterator-consume>>

    pub fn next(it: *ConfigIterator) !?Pair {
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

        const value = blk: {
            const tmp = try it.oneOf(&.{ .identifier, .string });
            switch (tmp.tag) {
                .identifier => break :blk it.token.text[tmp.data.start..tmp.data.end],
                .string => while (true) {
                    const token = try it.consume();
                    switch (token.tag) {
                        .string => break :blk it.token.text[tmp.data.end..token.data.start],
                        .newline => return error.UnexpectedNewline,
                        else => {},
                    }
                } else return error.StringNotClosed,
                else => unreachable,
            }
        };

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
            .value = value,
        };
    }
};
```

**iterator-consume**
```zig
fn consume(it: *@This()) !Token {
    const found = it.token.next();
    if (found.tag == .eof) return error.UnexpectedEof;
    return found;
}
```

**iterator-one-of**
```zig
fn oneOf(it: *@This(), expected: []const Token.Tag) !Token {
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
```

**iterator-expect**
```zig
fn expect(it: *@This(), expected: Token.Tag) !void {
    _ = try it.oneOf(&.{expected});
}
```


**configuration-booleans**
```zig
const boolean = ComptimeStringMap(bool, .{
    .{ "yes", true },
    .{ "true", true },
    .{ "y", true },
    .{ "no", false },
    .{ "false", false },
    .{ "n", false },
});
```


```zig
<<copyright-comment>>
const std = @import("std");
const testing = std.testing;
const meta = std.meta;
const mem = std.mem;
const ComptimeStringMap = std.ComptimeStringMap;

const lib = @import("lib");
const Tokenizer = lib.Tokenizer;
const Token = Tokenizer.Token;

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

<<command-line-iterator>>

<<configuration-iterator>>

<<configuration-booleans>>

pub fn parse(comptime T: type, text: []const u8) !T {
    const fields = meta.fields(T);

    var result: T = undefined;
    var it = ConfigIterator{ .token = Tokenizer{ .text = text } };
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


