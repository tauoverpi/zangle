const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Parser = @import("Parser.zig");
const TokenList = Parser.TokenList;
const NodeList = Parser.NodeList;
const Node = Parser.Node;
const RootIndex = Parser.RootIndex;
const NameMap = Parser.NameMap;

pub const Tree = @This();
text: []const u8,
// TODO: you can probably remove this
tokens: TokenList.Slice,
nodes: NodeList.Slice,
roots: []RootIndex,
name_map: NameMap,

pub fn parse(gpa: *Allocator, text: []const u8) !Tree {
    var p = try Parser.init(gpa, text);
    try p.resolve();
    return Tree{
        .text = p.text,
        .tokens = p.tokens,
        .nodes = p.nodes.toOwnedSlice(),
        .roots = p.roots.toOwnedSlice(gpa),
        .name_map = p.name_map,
    };
}

fn getToken(tree: Tree, index: usize) Token {
    const starts = tree.tokens.items(.start);
    var tokenizer: Tokenizer = .{ .text = tree.text, .index = starts[index].index };
    return tokenizer.next();
}

pub fn getTokenSlice(tree: Tree, index: Node.Index) []const u8 {
    const token = tree.getToken(index);
    return tree.text[token.data.start..token.data.end];
}

pub fn deinit(d: *Tree, gpa: *Allocator) void {
    d.tokens.deinit(gpa);
    d.nodes.deinit(gpa);
    gpa.free(d.roots);
    d.name_map.deinit(gpa);
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
        std.log.debug("token {}", .{token});
        if (token == .newline and i != end - start) {
            try writer.writeByteNTimes(' ', indent);
        }
    }
}

pub const RenderNode = struct { node: Node.Index, last: usize, offset: usize };

pub fn filename(tree: Tree, root: RootIndex) []const u8 {
    const tokens = tree.nodes.items(.token);
    const name = tree.getTokenSlice(tokens[root.index - 1]);
    return name[1 .. name.len - 1];
}

pub fn render(tree: Tree, stack: *std.ArrayList(RenderNode), root: RootIndex, writer: anytype) !void {
    const log = std.log.scoped(.render);

    const tags = tree.nodes.items(.tag);
    const tokens = tree.nodes.items(.token);
    const starts = tree.tokens.items(.start);
    const data = tree.nodes.items(.data);

    try stack.append(.{
        .node = root.index + 1,
        .last = root.index,
        .offset = 0,
    });

    var next_indent: Parser.Indent = 0;
    var indent: Parser.Indent = 0;

    while (stack.items.len > 0) {
        var index = stack.items.len - 1;
        var item = stack.items[index];
        std.log.debug("depth {} item {}", .{
            stack.items.len,
            item,
        });

        if (tags[item.node] == .placeholder) {
            indent = next_indent;
            next_indent = data[item.node];
        } else {
            assert(tags[item.node] == .end);
            if (stack.items.len == 0) return;

            const start = tokens[item.last] + @intCast(Node.Index, item.offset);
            const end = tokens[item.node];
            try tree.renderBlock(start, end, indent, writer);

            _ = stack.pop();

            continue;
        }

        stack.items[index].node = item.node + 1;
        stack.items[index].last = item.node;
        stack.items[index].offset = 2;

        const slice = tree.getTokenSlice(tokens[item.node]);
        const node = tree.name_map.get(slice) orelse return error.UnboundPlaceholder;
        const start = tokens[item.last] + @intCast(Node.Index, item.offset);
        const end = tokens[item.node] - 1;

        try tree.renderBlock(start, end, indent, writer);

        for (stack.items) |prev| if (prev.node == node) return error.CycleDetected;

        try stack.append(.{
            .node = node + 1,
            .last = node,
            .offset = 0,
        });
    }
}

fn testRender(input: []const u8, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;

    var tree = try Tree.parse(allocator, input);
    defer tree.deinit(std.testing.allocator);

    var stream = std.ArrayList(u8).init(allocator);
    defer stream.deinit();

    var stack = std.ArrayList(Tree.RenderNode).init(allocator);
    defer stack.deinit();

    for (expected) |expect, i| {
        defer stream.shrinkRetainingCapacity(0);

        try tree.render(&stack, tree.roots[i], stream.writer());

        testing.expectEqualStrings(expect, stream.items);
    }
}

test "render python" {
    try testRender(
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
        \\return answer
        \\```
    , &.{
        \\def universe(question):
        \\    answer = 42 # comment
        \\    # then return the truth
        \\    return answer
    });
}

test "multiple outputs" {
    try testRender(
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
    );
    defer tree.deinit(std.testing.allocator);
    testing.expectEqualStrings("test.zig", tree.filename(tree.roots[0]));
}
