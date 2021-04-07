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
const lib = @import("lib");
const testing = std.testing;
const fs = std.fs;
const log = std.log;
const io = std.io;
const ArrayList = std.ArrayList;
const Tree = lib.Tree;
const Parser = lib.Parser;
```

The module also makes sure to reference all definitions within locally
imported modules such as the configuration module through Zig's testing
module using `testing.refAllDecls(config)`.

**main-imports**
```zig
const config = @import("config.zig");

test {
    <<main-test-case>>;
}
```

**main**
```zig
<<copyright-comment>>

<<main-imports>>

const Configuration = config.Configuration;

pub fn main() !void {
    var instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _= instance.deinit();
    const gpa = &instance.allocator;

    var args = <<parse-configuration-parameters>>;

    defer for (args.files.items) |filename| {
        gpa.free(filename);
    } else args.files.deinit(gpa);

    var source = ArrayList(u8).init(gpa);
    defer source.deinit();

    for (args.files.items) |filename| {
        var file = try fs.cwd().openFile(filename, .{});
        defer file.close();

        try file.reader().readAllArrayList(&source, 0xffff_ffff);
    }

    var errors: []Parser.Error = undefined;
    var tree = Tree.parse(gpa, source.items, .{
        .delimiter = args.delimiter,
        .errors = &errors,
    }) catch |e| {
        const stderr = io.getStdErr();
        for (errors) |err| {
            try err.describe(source.items, .{
                .colour = args.colour,
            }, stderr.writer());
        }
        gpa.free(errors);

        if (args.debug_fail) {
            return e;
        } else {
            return;
        }
    };

    defer tree.deinit(gpa);

    if (args.tangle) {
        var stack = ArrayList(Tree.RenderNode).init(gpa);
        var left= ArrayList(u8).init(gpa);
        var right= ArrayList(u8).init(gpa);
        defer stack.deinit();
        defer left.deinit();
        defer right.deinit();

        for (tree.roots) |root| {
            defer stack.shrinkRetainingCapacity(0);
            defer left.shrinkRetainingCapacity(0);
            defer right.shrinkRetainingCapacity(0);
            const filename = tree.filename(root);
            log.info("writing {s}", .{filename});

            var file = try fs.cwd().createFile(filename, .{
                .truncate = true,
            });
            defer file.close();

            var stream = io.bufferedWriter(file.writer());

            try tree.tangleInternal(&stack, &left, &right, root, stream.writer());

            try stream.flush();
        }
    }

    if (args.weave) |filename| {
        var file = try fs.cwd().createFile(filename, .{
            .truncate = true,
        });

        defer file.close();

        var stream = io.bufferedWriter(file.writer());

        try tree.weave(args.format, stream.writer());

        try stream.flush();
    }
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

**configuration-specification**
```zig
pub const Configuration = struct {
    colour: bool = true,
    tangle: bool = true,
    debug_fail: bool = false,
    delimiter: Delimiter = .chevron,
    weave: ?[]const u8 = null,
    format: Weaver = .github,
    files: ArrayListUnmanaged([]const u8) = .{},
};
```

**configuration-specification**
```zig
const ConfigTag = meta.FieldEnum(Configuration);

const long = ComptimeStringMap(ConfigTag, .{
  .{ "tangle", .tangle },
  .{ "no-tangle", .tangle },
  .{ "debug-fail", .debug_fail},
  .{ "no-debug-fail", .debug_fail},
  .{ "colour", .colour},
  .{ "no-colour", .colour},
  .{ "color", .colour},
  .{ "no-color", .colour},
});

const pair = ComptimeStringMap(ConfigTag, .{
  .{ "delimiter", .delimiter },
  .{ "weave", .weave },
  .{ "format", .format },
});
```

**parse-configuration-parameters**
```zig
blk: {
  var parameters: Configuration = .{};

  try config.parseConfigFile(gpa, &parameters);
  try config.parseCliArgs(gpa, &parameters);

  break :blk parameters;
}
```

```zig
const std = @import("std");
const lib = @import("lib");
const testing = std.testing;
const meta = std.meta;
const mem = std.mem;
const fs = std.fs;
const process = std.process;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ComptimeStringMap = std.ComptimeStringMap;
const Tokenizer = lib.Tokenizer;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Delimiter = lib.Parser.Delimiter;
const Weaver = lib.Tree.Weaver;

<<configuration-specification>>

<<cli-parser>>

<<configuration-file-parser>>
```

Command-line arguments for this program are classified into the four categories
of `file` for file arguments, `long` for long options prefixed with a double
dash, `short` for the single byte equivalent prefixed with a single dash,
`pair` for long arguments that require parameters which are separated by
`=`, and `escape`, represented by a double dash, which declares that all
following arguments should be read as files even if they have a dash prefix.

**cli-argument-type**
```zig
const Arg = union(enum) {
    pair: Pair,
    file: []const u8,
    long: []const u8,
    short: u8,
    escape,

    pub const Pair = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn value(self: Arg) ?[]const u8 {
        switch (self) {
            .pair => |p| return p.value,
            else => return null,
        }
    }
};
```

The parser for command-line arguments.

**cli-parser**
```zig
<<cli-argument-type>>

pub fn parseCliArgs(gpa: *Allocator, out: *Configuration) !void {
    var escaped = false;
    var it = std.process.args();
    gpa.free(try it.next(gpa) orelse return);
    while (true) {
        const slice = try it.next(gpa) orelse return;
        errdefer gpa.free(slice);

        const param = try parseCliParam(slice);

        if (param == .file or escaped) {
            try out.files.append(gpa, slice);
        } else {
            switch (param) {
                .long => |l| switch (long.get(l) orelse return error.UnknownLong) {
                    .tangle => out.tangle = !mem.eql(u8, "no-", l[0..3]),
                    .colour => out.colour = !mem.eql(u8, "no-", l[0..3]),
                    .debug_fail => out.debug_fail = !mem.eql(u8, "no-", l[0..3]),
                    else => unreachable,
                },

                .short => |s| switch (s) {
                    't' => out.tangle = true,
                    else => unreachable,
                },

                .pair => |p| switch (pair.get(p.key) orelse return error.UnknownPair) {
                    .delimiter => out.delimiter = meta.stringToEnum(
                        Delimiter,
                        p.value
                    ) orelse return error.InvalidDelimiter,

                    .weave => if (out.weave == null) {
                      out.weave = p.value;
                    } else return error.MultipleWeaveTargets,

                    .format => out.format = meta.stringToEnum(
                        Weaver,
                        p.value,
                    ) orelse return error.InvalidWeaveFormat,

                    else => unreachable,
                },
                .escape => escaped = true,
                .file => unreachable,
            }
            gpa.free(slice);
        }
    }
}
```



**cli-parser**
```zig
fn parseCliParam(text: []const u8) !Arg {
    var token: Tokenizer = .{ .text = text };

    const line = token.next();
    switch (line.tag) {
        .line_fence => switch (line.len()) {
            1 => {
              const byte = token.next();
              if (byte.tag != .identifier or byte.len() != 1) return error.InvalidShortParameter;
              return Arg{ .short = byte.slice(text)[0] };
            },
            2 => {
                const name = token.next();
                if (name.tag == .eof) return Arg.escape;
                if (name.tag != .identifier) return error.InvalidLongParameter;

                const equal = token.next();
                switch (equal.tag) {
                    .eof => return Arg{ .long = name.slice(text) },

                    .equal => {
                        const trail = text[equal.data.end..];
                        if (trail.len == 0) return error.InvalidLongParameterArg;
                        return Arg{ .pair = .{
                          .key = name.slice(text),
                          .value = trail,
                        } };
                    },

                    else => return error.InvalidLongParameter,
                }
            },

            else => return error.InvalidFlagPrefix,
        },

        .eof => return error.InvalidFileName,

        else => return Arg{ .file = text },
    }
}
```

**cli-parser**
```zig
test "parse cli parameter" {
    testing.expectEqual(@as(u8, 'f'), (try parseCliParam("-f")).short);
    testing.expectEqualStrings("watch", (try parseCliParam("--watch")).long);
    testing.expectEqualStrings("one", (try parseCliParam("--count-thing=one")).pair.value);
    testing.expectEqualStrings("count", (try parseCliParam("--count=one")).pair.key);
    testing.expectEqualStrings("foo.zig", (try parseCliParam("foo.zig")).file);
    testing.expectEqual(Arg.escape, try parseCliParam("--"));

    testing.expectError(error.InvalidShortParameter, parseCliParam("- -"));
    testing.expectError(error.InvalidLongParameter, parseCliParam("--a|b"));
    testing.expectError(error.InvalidFlagPrefix, parseCliParam("---"));
    testing.expectError(error.InvalidFileName, parseCliParam(""));
    testing.expectError(error.InvalidLongParameterArg, parseCliParam("--stuff="));
}
```

**configuration-file-parser**
```zig
pub fn parseConfigFile(gpa: *Allocator, out: *Configuration) !void {
    var region = ArenaAllocator.init(gpa);
    defer region.deinit();

    const arena = &region.allocator;
    var path: []const u8 = try process.getCwdAlloc(arena);

    var file: fs.File = <<search-for-a-configuration-file>>;
    defer file.close();

    // TODO: parse config
}
```

**search-for-a-configuration-file**
```zig
while (true) {
    const filepath = try fs.path.join(arena, &.{path, ".zangle"});
    break fs.cwd().openFile(filepath, .{}) catch {
        if (fs.path.dirname(path)) |parent| {
            path = parent;
            continue;
        }
        return;
    };
} else unreachable
```
