const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;
const meta = std.meta;
const math = std.math;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

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
    p.delimiter = options.delimiter;
    p.resolve() catch |e| {
        if (options.errors) |ptr| {
            ptr.* = p.errors.toOwnedSlice(gpa);
        } else {
            p.errors.deinit(gpa);
        }

        p.deinit();
        return e;
    };
    var self = Tree{
        .text = p.text,
        .tokens = p.tokens,
        .nodes = p.nodes.toOwnedSlice(),
        .roots = p.roots.toOwnedSlice(gpa),
        .name_map = p.name_map,
        .doctests = p.doctests.toOwnedSlice(gpa),
    };
    errdefer self.deinit(gpa);
    try typeCheck(self, gpa, options.errors);
    return self;
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

fn typeCheck(tree: Tree, gpa: *Allocator, errors: ?*[]Parser.Error) !void {
    const tags = tree.nodes.items(.tag);
    const tokens = tree.nodes.items(.token);
    var block_type: []const u8 = undefined;
    var err = false;
    var list = ArrayListUnmanaged(Parser.Error){};
    for (tags) |tag, i| switch (tag) {
        .type => block_type = tree.getTokenSlice(tokens[i]),
        .placeholder => {
            const placeholder = tree.getTokenSlice(tokens[i]);
            const node = tree.name_map.get(placeholder) orelse {
                err = true;
                continue;
            };

            const Pair = struct { type: []const u8, token: Tokenizer.Token };

            const node_type = tree.getTokenSlice(tokens[node.head - 1]);
            const colon = tree.getTokenSlice(tokens[i] + 1);
            if (mem.eql(u8, ":", colon)) {
                const pair: Pair = blk: {
                    if (tree.getToken(tokens[node.head] + 3).tag == .l_paren) {
                        // get the defined cast type
                        const index = tokens[node.head] + 4;
                        break :blk .{
                            .type = tree.getTokenSlice(index),
                            .token = tree.getToken(index),
                        };
                    } else {
                        // get the explicit type
                        const index = tokens[node.head] + 2;
                        break :blk .{
                            .type = tree.getTokenSlice(index),
                            .token = tree.getToken(index),
                        };
                    }
                };

                if (!mem.eql(u8, node_type, pair.type)) {
                    err = true;
                    if (errors != null) try list.append(gpa, .{
                        .code = .{ .type_error = node_type },
                        .token = pair.token,
                    });
                }
            } else {
                if (!mem.eql(u8, block_type, node_type)) {
                    err = true;
                    if (errors != null) try list.append(gpa, .{
                        .code = .{ .type_error = block_type },
                        .token = tree.getToken(tokens[i]),
                    });
                }
            }
        },
        else => {},
    };

    if (errors) |e| e.* = list.toOwnedSlice(gpa);
    if (err) return error.TypeCheckFailed;
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

fn getFilename(tree: Tree, node: Node.Index) []const u8 {
    const start = tree.getToken(node);

    var tokenizer: Tokenizer = .{
        .text = tree.text,
        .index = start.data.end,
    };

    if (start.tag == .string) {
        while (true) switch (tokenizer.next().tag) {
            .string => return tree.text[start.data.end .. tokenizer.index - 1],
            else => |token| {
                assert(token != .newline);
                assert(token != .eof);
            },
        };
    } else {
        while (true) switch (tokenizer.next().tag) {
            .space, .r_brace => return tree.text[start.data.start .. tokenizer.index - 1],
            else => |token| {
                assert(token != .newline);
                assert(token != .eof);
            },
        };
    }
}

pub fn filename(tree: Tree, root: RootIndex) []const u8 {
    const tokens = tree.nodes.items(.token);
    const name = tree.getFilename(tokens[root.index - 2]);
    return name;
}

pub fn tangle(tree: Tree, gpa: *Allocator, root: RootIndex, writer: anytype) !void {
    var stack = ArrayList(RenderNode).init(gpa);
    defer stack.deinit();

    var left = ArrayList(u8).init(gpa);
    defer left.deinit();

    var right = ArrayList(u8).init(gpa);
    defer right.deinit();

    try tree.tangleInternal(&stack, &left, &right, root, writer);
}

const FilterItem = union(enum) {
    none,
    filter: Filter,

    pub const Direction = enum { left, right };

    pub const Filter = struct {
        direction: Direction,
        node: Node.Index,
        index: usize,
    };
};

pub const RenderNode = struct {
    node: Node.Index,
    last: usize,
    offset: usize,
    indent: Parser.Indent,
    trail: []Node.Index,
    filter: FilterItem = .none,
};

pub fn tangleInternal(
    tree: Tree,
    stack: *ArrayList(RenderNode),
    left: *ArrayList(u8),
    right: *ArrayList(u8),
    root: RootIndex,
    writer: anytype,
) !void {
    // The Game, you just lost it
    const tags = tree.nodes.items(.tag);
    const tokens = tree.nodes.items(.token);
    const starts = tree.tokens.items(.start);
    const data = tree.nodes.items(.data);

    left.shrinkRetainingCapacity(0);
    right.shrinkRetainingCapacity(0);
    var lindex: usize = 0;
    var rindex: usize = 0;
    var direction: ?FilterItem.Direction = null;
    try stack.append(.{
        .node = root.index + 1,
        .last = root.index,
        .offset = 0,
        .indent = 0,
        .trail = &.{},
        .filter = .none,
    });

    var indent: Parser.Indent = 0;
    testing.log_level = .debug;

    while (stack.items.len > 0) {
        var index = stack.items.len - 1;
        var item = stack.items[index];

        if (tags[item.node] != .placeholder) {
            assert(tags[item.node] == .end);
            if (stack.items.len == 0) return;

            const start = tokens[item.last] + @intCast(Node.Index, item.offset);
            const end = tokens[item.node];
            // check if block is empty
            try tree.renderBlock(start, end, indent, writer);

            _ = stack.pop();

            if (item.trail.len == 0) indent = math.sub(Parser.Indent, indent, item.indent) catch 0;

            for (item.trail) |_, i| {
                const trail = item.trail[(item.trail.len - 1) - i];
                try stack.append(.{
                    .node = trail + 1,
                    .last = trail,
                    .indent = if (i == item.trail.len - 1) item.indent else 0,
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

            try tree.renderBlock(start, end, indent, writer);

            for (stack.items) |prev| if (prev.node == node.head) return error.CycleDetected;

            var filter: FilterItem = .none;

            indent += data[item.node];
            try stack.append(.{
                .node = node.head + 1,
                .last = node.head,
                .offset = 0,
                .indent = data[item.node],
                .trail = node.trail.items,
                .filter = filter,
            });
        }
    }
}

fn testTangle(input: []const u8, expected: anytype) !void {
    const allocator = std.testing.allocator;

    var tree = try Tree.parse(allocator, input, .{});
    defer tree.deinit(std.testing.allocator);

    var stream = ArrayList(u8).init(allocator);
    defer stream.deinit();

    testing.log_level = .debug;
    inline for (meta.fields(@TypeOf(expected))) |field, i| {
        const expect = @field(expected, field.name);
        defer stream.shrinkRetainingCapacity(0);
        try tree.tangle(allocator, tree.roots[i], stream.writer());
        testing.expectEqualStrings(expect, stream.items);
        testing.expectEqualStrings(field.name, tree.filename(tree.roots[i]));
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
    , .{ .@"example.zig" = 
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
        \\```{.txt file="foo.zig"}
        \\<<a>> <<b>>
        \\```
    , .{ .@"foo.zig" = 
    \\one two
    });
}

test "render ignore type signature" {
    if (true) return error.SkipZigTest;
    try testTangle(
        \\```{.zig #a}
        \\a
        \\```
        \\
        \\```{.zig file="thing.zig"}
        \\<<a:zig>>
        \\```
    , .{ .@"thing.zig" = 
    \\a
    });
}

test "render bare filename" {
    try testTangle(
        \\```{.zig file=a.zig}
        \\a
        \\```
    , .{ .@"a.zig" = 
    \\a
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
    , .{
        .@"render.zig" = 
        \\const Tree = struct {};
        \\// A
        ,
        .@"parse.zig" = 
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
                                .type, .filename => {},
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
                        .type, .filename => {},
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
