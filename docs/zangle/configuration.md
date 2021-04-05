# Configuration

```{.zig #configuration-specification}
pub const Configuration = struct {
    tangle: bool = true,
    delimiter: Delimiter = .chevron,
    weave: ?[]const u8 = null,
    format: Weaver = .github,
    files: ArrayListUnmanaged([]const u8) = .{},
};
```

```{.zig #configuration-specification}
const ConfigTag = meta.FieldEnum(Configuration);

const long = ComptimeStringMap(ConfigTag, .{
  .{ "tangle", .tangle },
  .{ "no-tangle", .tangle },
});

const pair = ComptimeStringMap(ConfigTag, .{
  .{ "delimiter", .delimiter },
  .{ "weave", .weave },
  .{ "format", .format },
});
```

```{.zig #parse-configuration-parameters}
blk: {
  var parameters: Configuration = .{};

  try config.parseConfigFile(gpa, &parameters);
  try config.parseCliArgs(gpa, &parameters);

  break :blk parameters;
}
```

```{.zig file="src/config.zig"}
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

```{.zig #cli-argument-type}
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

```{.zig #cli-parser}
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
                    .tangle => out.tangle = !mem.startsWith(u8, "no-", l),
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



```{.zig #cli-parser}
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

```{.zig #cli-parser}
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

```{.zig #configuration-file-parser}
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

```{.zig #search-for-a-configuration-file}
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
