const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;
const meta = std.meta;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Parser = @import("Parser.zig");
const TokenList = Parser.TokenList;
const NodeList = Parser.NodeList;
const Node = Parser.Node;
const RootIndex = Parser.RootIndex;
const NameMap = Parser.NameMap;
const Name = Parser.Name;
const DocTestList = Parser.DocTestList;
const DocTest = Parser.DocTest;

pub const Tree = @This();

text: []const u8,
tokens: TokenList.Slice,
nodes: NodeList.Slice,
roots: []RootIndex,
name_map: NameMap,
doctests: []DocTest,

pub const ParserOptions = struct {
    delimiter: Parser.Delimiter = .chevron,
    errors: ?*[]Parser.Error = null,
};

pub fn parse(gpa: *Allocator, text: []const u8, options: ParserOptions) !Tree {
    var p = try Parser.init(gpa, text);
    errdefer p.deinit();
    p.delimiter = options.delimiter;
    p.resolve() catch |e| {
        if (options.errors) |ptr| {
            ptr.* = p.errors.toOwnedSlice(gpa);
        } else {
            p.errors.deinit(gpa);
        }
        return e;
    };
    return Tree{
        .text = p.text,
        .tokens = p.tokens,
        .nodes = p.nodes.toOwnedSlice(),
        .roots = p.roots.toOwnedSlice(gpa),
        .name_map = p.name_map,
        .doctests = p.doctests.toOwnedSlice(gpa),
    };
}

fn getToken(tree: Tree, index: usize) Token {
    const starts = tree.tokens.items(.start);
    var tokenizer: Tokenizer = .{ .text = tree.text, .index = starts[index].index };
    return tokenizer.next();
}

pub fn getTokenSlice(tree: Tree, index: Node.Index) []const u8 {
    const token = tree.getToken(index);
    return token.slice(tree.text);
}

pub fn deinit(tree: *Tree, gpa: *Allocator) void {
    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.roots);
    var it = tree.name_map.iterator();
    while (it.next()) |entry| entry.value.trail.deinit(gpa);
    tree.name_map.deinit(gpa);
}

fn renderBlock(
    tree: Tree,
    start: Node.Index,
    end: Node.Index,
    indent: Parser.Indent,
    writer: anytype,
) !void {
    const tokens = tree.tokens.items(.tag);
    for (tokens[start..end]) |token, i| {
        try writer.writeAll(tree.getTokenSlice(start + @intCast(Node.Index, i)));
        if (token == .newline and i != end - start) {
            try writer.writeByteNTimes(' ', indent);
        }
    }
}

pub const RenderNode = struct {
    node: Node.Index,
    last: usize,
    offset: usize,
    indent: Parser.Indent,
    trail: []Node.Index,
    depth: ?usize = null,
    stack: usize = undefined,
};

fn getString(tree: Tree, node: Node.Index) []const u8 {
    const start = tree.getToken(node);
    assert(start.tag == .string);

    var tokenizer: Tokenizer = .{
        .text = tree.text,
        .index = start.data.end,
    };

    while (true) switch (tokenizer.next().tag) {
        .string => return tree.text[start.data.end .. tokenizer.index - 1],
        else => |token| {
            assert(token != .newline);
            assert(token != .eof);
        },
    };
}

pub fn filename(tree: Tree, root: RootIndex) []const u8 {
    const tokens = tree.nodes.items(.token);
    const name = tree.getString(tokens[root.index - 1]);
    return name;
}

const Filter = enum {
    escape,
};

const builtin_filters = std.ComptimeStringMap(Filter, .{
    .{ "escape", .escape },
});

const EscapeFilter = enum {
    html,
    zig_string,
};

const escape_filter_mode = std.ComptimeStringMap(EscapeFilter, .{
    .{ "html", .html },
    .{ "zig-string", .zig_string },
});

pub fn tangle(
    tree: Tree,
    stack: *ArrayList(RenderNode),
    scratch: *ArrayList(u8),
    root: RootIndex,
    writer: anytype,
) !void {
    // The Game, you just lost it
    const tags = tree.nodes.items(.tag);
    const tokens = tree.nodes.items(.token);
    const starts = tree.tokens.items(.start);
    const data = tree.nodes.items(.data);

    scratch.shrinkRetainingCapacity(0);

    try stack.append(.{
        .node = root.index + 1,
        .last = root.index,
        .offset = 0,
        .indent = 0,
        .trail = &.{},
    });

    var depth: usize = 1;
    var filter: ?usize = null;
    var indent: Parser.Indent = 0;

    while (stack.items.len > 0) {
        var index = stack.items.len - 1;
        var item = stack.items[index];

        if (tags[item.node] != .placeholder) {
            assert(tags[item.node] == .end);
            if (stack.items.len == 0) return;

            const start = tokens[item.last] + @intCast(Node.Index, item.offset);
            const end = tokens[item.node];
            // check if block is empty
            if (start < end) try tree.renderBlock(start, end, item.indent, writer);

            _ = stack.pop();

            if (filter) |f_depth| {
                if (f_depth == depth) {
                    filter = null;
                }
            }

            depth -= 1;

            for (item.trail) |_, i| {
                depth += 1;
                const trail = item.trail[(item.trail.len - 1) - i];
                try stack.append(.{
                    .node = trail + 1,
                    .last = trail,
                    .indent = item.indent,
                    .offset = 0,
                    .trail = &.{},
                });
            }
        } else {
            stack.items[index].node = item.node + 1;
            stack.items[index].last = item.node;
            stack.items[index].offset = 2;

            const token = tokens[item.node];
            const slice = tree.getTokenSlice(token);
            const maybe_sep = tree.getToken(token + 1);
            const node = tree.name_map.get(slice) orelse {
                return error.UnboundPlaceholder;
            };
            const start = tokens[item.last] + @intCast(Node.Index, item.offset);
            const end = tokens[item.node] - 1;

            try tree.renderBlock(start, end, item.indent, writer);

            for (stack.items) |prev| if (prev.node == node.head) return error.CycleDetected;

            depth += 1;

            if (maybe_sep.tag == .fence) {
                filter = depth;
            } else if (maybe_sep.tag == .pipe) {
                filter = depth;
            }

            try stack.append(.{
                .node = node.head + 1,
                .last = node.head,
                .offset = 0,
                .indent = data[item.node],
                .trail = node.trail.items,
            });
        }
    }

    assert(depth == 0);
}

fn testTangle(input: []const u8, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;

    var tree = try Tree.parse(allocator, input, .{});
    defer tree.deinit(std.testing.allocator);

    var stream = ArrayList(u8).init(allocator);
    defer stream.deinit();

    var stack = ArrayList(Tree.RenderNode).init(allocator);
    defer stack.deinit();

    var scratch = ArrayList(u8).init(allocator);
    defer scratch.deinit();

    for (expected) |expect, i| {
        defer stream.shrinkRetainingCapacity(0);

        try tree.tangle(&stack, &scratch, tree.roots[i], stream.writer());

        testing.expectEqualStrings(expect, stream.items);
    }
}

test "render python" {
    try testTangle(
        \\Testing `42`{.python #number} definitions.
        \\
        \\```{.python file="example.zig"}
        \\def universe(question):
        \\    <<block>>
        \\```
        \\
        \\```{.python #comment}
        \\# then return the truth
        \\```
        \\
        \\```{.python #block}
        \\answer = <<number>> # comment
        \\<<comment>>
        \\<<comment>>
        \\return answer
        \\```
    , &.{
        \\def universe(question):
        \\    answer = 42 # comment
        \\    # then return the truth
        \\    # then return the truth
        \\    return answer
    });
}

test "render double inline" {
    try testTangle(
        \\some text `one`{.txt #a} more text `two`{.txt #b}.
        \\```{.zig file="foo.zig"}
        \\<<a>> <<b>>
        \\```
    , &.{
        \\one two
    });
}

test "multiple outputs" {
    try testTangle(
        \\Rendering multiple inputs from the same tree
        \\works the same given `Tree`{.zig #tree-type}
        \\stroing all root nodes in order of discovery.
        \\
        \\```{.zig file="render.zig"}
        \\const <<tree-type>> = struct {};
        \\// A
        \\```
        \\
        \\```{.zig file="parse.zig"}
        \\const <<tree-type>> = struct {};
        \\```
        \\
    , &.{
        \\const Tree = struct {};
        \\// A
        ,
        \\const Tree = struct {};
    });
}

test "filename" {
    var tree = try Tree.parse(std.testing.allocator,
        \\```{.zig file="test.zig"}
        \\```
    , .{});
    defer tree.deinit(std.testing.allocator);
    testing.expectEqualStrings("test.zig", tree.filename(tree.roots[0]));
}

pub const Weaver = enum {
    github,
    pandoc,
    //elara,
};

pub fn weave(tree: Tree, weaver: Weaver, writer: anytype) !void {
    switch (weaver) {
        .github => try tree.weaveGithub(writer),
        .pandoc => try tree.weavePandoc(writer),
    }
}

pub fn weaveGithub(tree: Tree, writer: anytype) !void {
    var last: usize = 0;
    const tags = tree.nodes.items(.tag);
    const tokens = tree.nodes.items(.token);
    const data = tree.nodes.items(.data);
    const source = tree.tokens.items(.tag);
    var state: enum { scan, inline_block } = .scan;

    done: { // remove the title block if it exists
        const line = mem.indexOf(Tokenizer.Token.Tag, source, &.{.line_fence}) orelse break :done;

        if (line != 0) for (source[0..line]) |token| switch (token) {
            .newline, .space => {},
            else => break :done,
        };

        const dot = mem.indexOf(Tokenizer.Token.Tag, source, &.{ .newline, .dot_fence }) orelse break :done;

        if (line < dot and tokens[0] > dot) {

            //last = tree.getToken(dot + 1).data.end;
            for (source[dot + 2 ..]) |token, i| switch (token) {
                .space => {},
                .newline => last = tree.getToken(dot + i + 2).data.end,
                else => break,
            };
        }
    }

    for (tags) |tag, i| switch (state) {
        .scan => {
            switch (tag) {
                .block => if (Node.BlockData.cast(data[i]).inline_block) {
                    state = .inline_block;
                } else {
                    const r_brace = tree.getToken(tokens[i] - 2);
                    if (r_brace.tag == .r_brace) {
                        if (mem.lastIndexOfScalar(Tokenizer.Token.Tag, source[0..tokens[i]], .l_brace)) |l_brace| {
                            const fence = tree.getToken(l_brace - 1);
                            const here = tree.getToken(l_brace).data.start;
                            const slice = tree.text[last .. here - fence.len()];
                            var j: usize = 1;

                            try writer.writeAll(slice);

                            while (j <= i) : (j += 1) switch (tags[i - j]) {
                                .filename => {},
                                .tag => try writer.print("**{s}**\n", .{tree.getTokenSlice(tokens[i - j])}),
                                else => break,
                            };

                            try writer.print("{s}{s}", .{
                                fence.slice(tree.text),
                                tree.getTokenSlice(@intCast(Node.Index, l_brace + 2)),
                            });
                            last = r_brace.data.end;
                            continue;
                        }
                    }
                },
                else => continue,
            }
            const found = tree.getToken(tokens[i]);
            const slice = tree.text[last..found.data.end];
            try writer.writeAll(slice);
            last += slice.len;
        },

        .inline_block => {
            const found = tree.getToken(tokens[i]);
            assert(tags[i] == .end);
            try writer.writeAll(tree.text[last..found.data.end]);
            if (source[tokens[i] + 1] == .l_brace) {
                if (mem.indexOfScalarPos(Tokenizer.Token.Tag, source, tokens[i] + 1, .r_brace)) |index| {
                    last = tree.getToken(index).data.end;
                } else {
                    last = found.data.end;
                }
            } else {
                last = found.data.end;
            }
            state = .scan;
        },
    };

    try writer.writeAll(tree.text[last..]);
}

test "weave github" {
    try testWeave(.github, "Example `text`{.zig} in a block", "Example `text` in a block");
    try testWeave(.github, "Example `text`{.zig}", "Example `text`");
    try testWeave(.github,
        \\```{.zig #a}
        \\```
    ,
        \\**a**
        \\```zig
        \\```
    );
    try testWeave(.github,
        \\---
        \\...
        \\```{.zig #a}
        \\```
    ,
        \\**a**
        \\```zig
        \\```
    );
    try testWeave(.github,
        \\---
        \\...
        \\
        \\
        \\
        \\```{.zig #a}
        \\```
    ,
        \\**a**
        \\```zig
        \\```
    );
    try testWeave(.github,
        \\---
        \\```{.zig #a}
        \\```
        \\...
    ,
        \\---
        \\**a**
        \\```zig
        \\```
        \\...
    );
}

pub fn weavePandoc(tree: Tree, writer: anytype) !void {
    var last: usize = 0;
    const tags = tree.nodes.items(.tag);
    const tokens = tree.nodes.items(.token);
    const data = tree.nodes.items(.data);
    const source = tree.tokens.items(.tag);

    for (tags) |tag, i| switch (tag) {
        .block => if (!Node.BlockData.cast(data[i]).inline_block) {
            const r_brace = tree.getToken(tokens[i] - 2);
            if (r_brace.tag == .r_brace) {
                if (mem.lastIndexOfScalar(Tokenizer.Token.Tag, source[0..tokens[i]], .l_brace)) |l_brace| {
                    const fence = tree.getToken(l_brace - 1);
                    const here = tree.getToken(l_brace).data.start;
                    const slice = tree.text[last .. here - fence.len()];
                    var j: usize = 1;

                    try writer.writeAll(slice);

                    while (j <= i) : (j += 1) switch (tags[i - j]) {
                        .filename => {},
                        .tag => try writer.print("**{s}**\n", .{tree.getTokenSlice(tokens[i - j])}),
                        else => break,
                    };

                    try writer.writeAll(tree.text[last + slice.len .. r_brace.data.end]);
                    last = r_brace.data.end;
                    continue;
                }
            }
        },
        else => continue,
    };

    try writer.writeAll(tree.text[last..]);
}

test "weave pandoc" {
    try testWeave(.pandoc, "Example `text`{.zig} in a block", "Example `text`{.zig} in a block");
    try testWeave(.pandoc,
        \\```{.zig #a #b}
        \\```
    ,
        \\**b**
        \\**a**
        \\```{.zig #a #b}
        \\```
    );
}

fn testWeave(weaver: Weaver, input: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;

    var tree = try Tree.parse(allocator, input, .{});
    defer tree.deinit(allocator);

    var stream = ArrayList(u8).init(allocator);
    defer stream.deinit();

    try tree.weave(weaver, stream.writer());

    testing.expectEqualStrings(expected, stream.items);
}

pub fn Query(comptime tag: Node.Tag) type {
    return switch (tag) {
        .filename => struct {
            tree: Tree,
            index: usize = 0,

            pub fn next(it: *@This()) ?[]const u8 {
                if (it.index >= it.tree.nodes.len) return null;

                const tags = it.tree.nodes.items(.tag);
                const tokens = it.tree.nodes.items(.token);

                while (mem.indexOfPos(Node.Tag, tags, it.index, &.{.filename})) |file| {
                    const name = it.tree.getTokenSlice(tokens[file]);
                    it.index = file + 1;
                    return name;
                }

                return null;
            }
        },

        .block => struct {
            tree: Tree,
            index: usize = 0,

            pub fn next(it: *@This()) ?[]const u8 {
                if (it.index >= it.tree.nodes.len) return null;

                const tags = it.tree.nodes.items(.tag);
                const tokens = it.tree.nodes.items(.token);
                const tokens = it.tree.nodes.items(.data);

                while (mem.indexOfPos(Node.Tag, tags, it.index, &.{.filename})) |file| {
                    const name = it.tree.getTokenSlice(tokens[file]);
                    it.index = file + 1;
                    return name;
                }

                return null;
            }
        },

        else => @compileError("no query object defined for " ++ @tagName(tag) ++ " yet"),
    };
}

pub fn query(tree: Tree, comptime tag: Node.Tag, args: switch (tag) {
    .filename => void,
    else => @compileError("no query object defined for " ++ @tagName(tag) ++ " yet"),
}) Query(tag) {
    return Query(tag){ .tree = tree };
}

test "query" {
    var tree = try Tree.parse(std.testing.allocator, "", .{});
    defer tree.deinit(std.testing.allocator);

    var it = tree.query(.filename, {});

    _ = it.next();
}
