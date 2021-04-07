---
title: Zangle
documentclass: article
toc: true
geometry:
  - margin=0.6in
pagestyle: headings
links-as-notes: true
papersize: a4
...

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

```{.zig #main-imports}
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
module using `testing.refAllDecls(config)`{.zig #main-test-case}.

```{.zig #main-imports}
const config = @import("config.zig");

test {
    <<main-test-case>>;
}
```

```{.zig file="src/main.zig" #main}
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
