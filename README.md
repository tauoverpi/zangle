![Zangle logo](assets/svg/zangle.svg?raw=true)


ZANGLE                                                                     intro
================================================================================

Zangle is a tool for emitting code within markdown code blocks into files that a
regular toolchain can process with light preprocessing abilities. Code blocks
may be combined from one or more files and are emitted in the order they're
included in the document. This allows for a literate programming approach to
documenting both the design and implementation along with the program.

This program is unfinished and thus might not do what you expect at present.

TODO:

- [ ] Compile files presented on the command-line
- [ ] Pandoc markdown frontend (or just enough to work with it)
- [ ] Html5 frontend
- [ ] Zangle as a WebAssembly module
- [ ] Execution of `shell` commands
- [ ] Execution of commands
- rest of this list

ZANGLE                                                                   example
--------------------------------------------------------------------------------


    lang: zig esc: none file: out/main.zig
    --------------------------------------

    pub fn main() anyerror!void {
        std.log.info("Z-angle", .{});
    }
