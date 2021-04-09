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
    typecheck: bool = true,
};

pub fn parse(gpa: *Allocator, text: []const u8, options: ParserOptions) !Tree {
    var p = try Parser.init(gpa, text);
    errdefer p.deinit();
    p.delimiter = options.delimiter;
    errdefer |e| {
        if (options.errors) |ptr| {
            ptr.* = p.errors.toOwnedSlice(gpa);
        } else {
            p.errors.deinit(gpa);
        }
    }
    try p.resolve();
    if (options.typecheck) try p.typeCheck();

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
    gpa.free(tree.doctests);
    var it = tree.name_map.iterator();
    while (it.next()) |entry| entry.value.tail.deinit(gpa);
    tree.name_map.deinit(gpa);
}

fn renderBlock(
    tree: Tree,
    start: Node.Index,
    end: Node.Index,
    indent: usize,
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
    testing.log_level = .debug;

    var stack = ArrayList(struct {
        head: Node.Index,
        last: Node.Index,
        tail: []const Node.Index,
        indent: usize,
        data: Parser.Node.BlockData,
        is_trail: bool,
    }).init(gpa);
    defer stack.deinit();

    try stack.append(.{
        .head = root.index + 1,
        .last = root.index,
        .tail = &.{},
        .indent = 0,
        // don't care what the data is as it's never used
        .data = Node.BlockData.cast(0),
        .is_trail = false,
    });

    const tags = tree.nodes.items(.tag);
    const tokens = tree.nodes.items(.token);
    const indents = tree.nodes.items(.data);
    const blockdata = indents; // same field, different meaning
    const ttags = tree.tokens.items(.tag);

    var indent: usize = 0;
    while (stack.items.len > 0) {
        const node = &stack.items[stack.items.len - 1];

        // The tag before will only ever be a chevron if this is a
        // placeholder thus it's always safe to check for it.
        const offset = @intCast(Node.Index, if (ttags[tokens[node.last] - 1] == .l_chevron) 1 + mem.indexOfScalar(
            Tokenizer.Token.Tag,
            ttags[tokens[node.last]..],
            .r_chevron,
        ).? else 0);

        switch (tags[node.head]) {
            .placeholder => {
                const start = offset + tokens[node.last];
                const end = tokens[node.head] - 1;

                const block = tree.name_map.get(tree.getTokenSlice(tokens[node.head])).?;
                const data = Node.BlockData.cast(blockdata[block.head]);

                try stack.append(.{
                    .head = block.head + 1,
                    .last = block.head,
                    .tail = block.tail.items,
                    .indent = indent,
                    .data = data,
                    .is_trail = false,
                });

                try tree.renderBlock(start, end, indent, writer);

                indent += indents[node.head];
                node.head += 1;
                node.last += 1;
            },

            .end => {
                const term = stack.pop();
                const start = offset + tokens[term.last];
                const end = tokens[term.head];

                if (term.data.inline_block) {
                    try tree.renderBlock(start, end, indent, writer);
                    indent = term.indent;
                } else if (term.is_trail) {
                    if (term.indent == indent) {
                        try tree.renderBlock(start, end - 1, indent, writer);
                    } else {
                        try tree.renderBlock(start - 1, end - 1, indent, writer);
                    }
                } else if (term.tail.len == 0) {
                    // skip if a block is empty
                    if (start < end) {
                        try tree.renderBlock(start, end - 1, indent, writer);
                    }
                    indent = term.indent;
                } else {
                    try tree.renderBlock(start, end, indent, writer);
                }

                for (term.tail) |_, i| {
                    const n = term.tail.len - (i + 1);
                    const tail = term.tail[n];
                    try stack.append(.{
                        .head = tail + 1,
                        .last = tail,
                        .tail = &.{},
                        .indent = if (n != 0) term.indent else indent,
                        .data = Node.BlockData.cast(blockdata[tail]),
                        .is_trail = true,
                    });
                }
            },

            else => unreachable,
        }
    }
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

test "render inline inline" {
    try testTangle(
        \\example `:~`{.a #a}
        \\
        \\```{.a file=a}
        \\<<a>>
        \\```
    , .{ .a = 
    \\:~
    });
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
    try testTangle(
        \\```{.zig #a}
        \\a
        \\```
        \\
        \\```{.zig file="thing.zig"}
        \\<<a:from(zig)>>
        \\```
    , .{ .@"thing.zig" = 
    \\a
    });
}

test "render space before meta" {
    try testTangle(
        \\``` {.zig #a}
        \\a
        \\```
        \\
        \\```             {.zig file="thing.zig"}
        \\<<a:from(zig)>>
        \\```
    , .{ .@"thing.zig" = 
    \\a
    });
}

test "render inline" {
    try testTangle(
        \\`a`{.zig #a}
        \\`a`{.zig #a}
        \\`a`{.zig #a}
        \\```{.zig file=thing.zig}
        \\<<a>>
        \\```
    , .{ .@"thing.zig" = 
    \\aaa
    });
}

test "render indent" {
    try testTangle(
        \\```{.zig #a}
        \\@
        \\```
        \\```{.zig #b}
        \\#
        \\   <<a:from(zig)>>
        \\```
        \\```{.zig #c}
        \\#
        \\   <<b:zig>>
        \\```
        \\```{.zig #d}
        \\#
        \\   <<c>>
        \\```
        \\```{.zig #e}
        \\#
        \\   <<d:zig>>
        \\```
        \\```{.zig #b}
        \\#
        \\```
        \\```{.zig #b}
        \\#
        \\```
        \\```{.zig file=thing.zig}
        \\+
        \\  <<e:from(zig)>>
        \\+
        \\```
    , .{ .@"thing.zig" = 
    \\+
    \\  #
    \\     #
    \\        #
    \\           #
    \\              @
    \\           #
    \\           #
    \\+
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
    pandoc,
};

pub fn weave(tree: Tree, weaver: Weaver, writer: anytype) !void {
    switch (weaver) {
        .pandoc => try tree.weavePandoc(writer),
    }
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
