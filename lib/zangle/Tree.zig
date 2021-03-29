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

const Tree = struct {
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

    pub fn render(tree: Tree, arena: *Allocator, root: RootIndex, writer: anytype) !void {
        const log = std.log.scoped(.render);

        const tags = tree.nodes.items(.tag);
        const tokens = tree.nodes.items(.token);
        const starts = tree.tokens.items(.start);

        var stack = std.ArrayList(struct { node: Node.Index, offset: usize }).init(arena);
        try stack.append(.{
            .node = root.index + 1,
            .offset = starts[tokens[root.index]].index,
        });

        while (stack.items.len > 0) {
            log.debug("depth {}", .{stack.items.len});

            const index = stack.items.len - 1;
            const item = stack.items[index];
            stack.items[index].offset = starts[tokens[item.node]].index;

            if (tags[item.node] != .placeholder) {
                assert(tags[item.node] == .end);
                const end = starts[tokens[item.node] - 1].index;
                try writer.writeAll(tree.text[item.offset..end]);
                _ = stack.pop();
                continue;
            }

            stack.items[index].node += 1;

            const slice = tree.getTokenSlice(tokens[item.node]);
            const node = tree.name_map.get(slice) orelse return error.UnboundPlaceholder;
            const end = starts[tokens[item.node] - 1].index;

            try writer.writeAll(tree.text[item.offset..end]);

            for (stack.items) |prev| if (prev.node == node) return error.CycleDetected;

            try stack.append(.{
                .node = node + 1,
                .offset = starts[tokens[node]].index,
            });
        }
    }
};

test "render" {
    testing.log_level = .debug;
    var tree = try Tree.parse(std.testing.allocator,
        \\Testing `42`{.python #number} definitions.
        \\
        \\```{.python file="example.zig"}
        \\def universe(question):
        \\    <<block>>
        \\```
        \\
        \\```{.python #block}
        \\answer = <<number>> # comment
        \\return answer
        \\```
    );
    defer tree.deinit(std.testing.allocator);

    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    for (tree.nodes.items(.tag)) |node| {
        std.log.debug("{}", .{node});
    }

    try tree.render(&arena.allocator, tree.roots[0], fbs.writer());

    testing.expectEqualStrings(
        \\def universe(question):
        \\    answer = 42 # comment
        \\    return answer
    , fbs.getWritten());
}
