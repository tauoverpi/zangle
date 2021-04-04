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
const testing = std.testing;

const lib = @import("lib");
const Delimiter = lib.Parser.Delimiter;

const config = @import("config.zig");
```

The module also makes sure to reference all definitions within locally
imported modules such as the configuration module through Zig's testing
module using `testing.refAllDecls(config)`{.zig #main-test-case}.

```{.zig file="src/main.zig" #main}
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
