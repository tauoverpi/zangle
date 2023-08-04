![](assets/svg/logo.svg)

# Zangle

Zangle is a literate programming tool for extracting code fragments from
markdown and other types of text documents into separate files ready for
compilation.

NOTE: Currently zangle only supports markdown.

### Community

- matrix: https://matrix.to/#/#zangle:tchncs.de

### Building

- minimal requirements:
   + 0.11.0-dev.4410+76f7b40e1 or higher

```
$ zig build -Drelease
```

### Invocation

Let `book/` be a directory of markdown files.

Tangle all files within a document

    $ zangle tangle book/

List all files in a document

    $ zangle ls book/

Render the content of a tag to stdout

    $ zangle call book/ --tag='interpreter step'

Render a graph representing document structure

    $ zangle graph book/ | dot -Tpng -o grpah.png

Render a graph representing the structure of a single file output

    $ zangle graph book/ --file=lib/Linker.zig | dot -Tpng -o grpah.png

Find where given tags reside within output files (TODO)

    $ zangle find README.md --tag='parser codegen' --tag='command-line parser'

Create a new literate document from existing files (TODO)

    $ find src lib -name '*.zig' | zangle init build.zig --stdin > Zangle.md

### Example

This project fetches the real package from sr.ht using the new zig package manager however most options are the same as
the `init-exe` template with a few minor changes. The general structure follows:

``` zig file: build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    [[declare release and target options]]
    [[import zangle from the dependency list, set target parameters, and install the artifact]]
    [[setup a run command such that it can be tested without having write the path to the binary in zig-out]]
}
```

For the target options, `.ReleaseSafe` was chosen such that the program would panic as soon as it invokes [safety-checked
undefined behaviour](https://ziglang.org/documentation/0.10.1/#Undefined-Behavior).

``` zig tag: declare release and target options
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{
    .preferred_optimize_mode = .ReleaseSafe,
});
```

The package is hosted on sr.ht as a sub project of a game project which uses zangle to document every design choice made
for all code included in the final game.

``` zig file: build.zig.zon
.{
    .name = "zangle",
    .version = "0.3.0",

    .dependencies = .{
        .zangle = .{
            .url = "https://git.sr.ht/~tauoverpi/levy/archive/3d92a0f55775f815b6909cf9bd9a047716e67282.tar.gz",
        },
    },
}
```

In `build.zig`, the real zangle is loaded as a dependency and set to follow the local target and optimization
configuration.

``` zig tag: import zangle from the dependency list, set target parameters, and install the artifact
const dep = b.dependency("zangle", .{});
const zangle = dep.artifact("zangle");
zangle.target = target;
zangle.optimize = optimize;
```

Then installed with `b.installArtifact()` which also ensures that the executable is built upon invoking `zig build`.

``` zig tag: import zangle from the dependency list, set target parameters, and install the artifact
b.installArtifact(zangle);
```

Finally, testing out zangle should require no more than `zig build run` to invoke it.

``` zig tag: setup a run command such that it can be tested without having write the path to the binary in zig-out
const run_cmd = b.addRunArtifact(zangle);

run_cmd.step.dependOn(b.getInstallStep());

if (b.args) |args| {
    run_cmd.addArgs(args);
}

const run_step = b.step("run", "Run the app");
run_step.dependOn(&run_cmd.step);
```

This concludes the example zangle document with two files written where one included other tags.
