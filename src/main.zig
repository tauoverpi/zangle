const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Token = struct {
    /// Syntactic atom which this token represents.
    tag: Tag,

    /// Position where this token resides within the text.
    data: Data,

    pub const Data = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        eof,
        invalid,
        space,
        newline,
        text,
        fence,
        l_brace,
        r_brace,
        dot,
        identifier,
        equal,
        string,
        hash,
        l_chevron,
        r_chevron,
    };
};

const Tokenizer = struct {
    text: []const u8,
    index: usize = 0,

    const State = enum {
        start,
        fence,
        identifier,
        string,
        space,
        ignore,
        chevron,
    };

    pub fn next(self: *Tokenizer) Token {
        // since there are different kinds of fences we'll keep track
        // of which by storing the first byte. We don't care more than
        // this though as the parser is in charge of validating further.
        var fence: u8 = undefined;

        var token: Token = .{
            .tag = .eof,
            .data = .{
                .start = self.index,
                .end = undefined,
            },
        };

        var state: State = .start;

        while (self.index < self.text.len) : (self.index += 1) {
            const c = self.text[self.index];
            switch (state) {
                .start => switch (c) {
                    // simple tokens return their result directly

                    '.' => {
                        token.tag = .dot;
                        self.index += 1;
                        break;
                    },

                    '#' => {
                        token.tag = .hash;
                        self.index += 1;
                        break;
                    },

                    '=' => {
                        token.tag = .equal;
                        self.index += 1;
                        break;
                    },

                    '\n' => {
                        token.tag = .newline;
                        self.index += 1;
                        break;
                    },

                    // longer tokens require scanning further to fully resolve them

                    ' ' => {
                        token.tag = .space;
                        state = .space;
                    },

                    '`', '~', ':' => |ch| {
                        token.tag = .fence;
                        state = .fence;
                        fence = ch;
                    },

                    'a'...'z', 'A'...'Z', '_' => {
                        token.tag = .identifier;
                        state = .identifier;
                    },

                    '"' => {
                        token.tag = .string;
                        state = .string;
                    },

                    '<', '{' => |ch| {
                        token.tag = .l_chevron;
                        state = .chevron;
                        fence = ch;
                    },

                    '>', '}' => |ch| {
                        token.tag = .r_chevron;
                        state = .chevron;
                        fence = ch;
                    },

                    // ignore anything we don't understand and pretend it's just
                    // regular text

                    else => {
                        token.tag = .text;
                        self.index += 1;
                        state = .ignore;
                    },
                },

                .ignore => switch (c) {
                    // All valid start characters that this must break on
                    '.', '#', '=', '\n', ' ', '`', '~', ':', 'a'...'z', 'A'...'Z', '_', '"', '<', '{', '>', '}' => break,
                    else => {},
                },

                // states below match multi-character tokens

                .fence => if (c != fence) break,

                .chevron => if (c == fence) {
                    self.index += 1;
                    break;
                } else {
                    switch (fence) {
                        '{' => {
                            token.tag = .l_brace;
                            break;
                        },

                        '}' => {
                            token.tag = .r_brace;
                            break;
                        },

                        else => {
                            token.tag = .text;
                            break;
                        },
                    }
                },

                .identifier => switch (c) {
                    'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
                    else => break,
                },

                .string => switch (c) {
                    '\n', '\r' => {
                        token.tag = .invalid;
                        self.index += 1;
                        break;
                    },
                    '"' => {
                        self.index += 1;
                        break;
                    },
                    else => {},
                },

                .space => switch (c) {
                    ' ' => {},
                    else => break,
                },
            }
        } else switch (token.tag) {
            // eof before terminating the string
            .string => token.tag = .invalid,

            // handle braces at the end
            .r_chevron => if (fence == '}') {
                token.tag = .r_brace;
            },

            .l_chevron => if (fence == '{') {
                token.tag = .l_brace;
            },
            else => {},
        }

        // finally set the length
        token.data.end = self.index;

        return token;
    }
};

fn testTokenizer(text: []const u8, tags: []const Token.Tag) void {
    var p: Tokenizer = .{ .text = text };
    for (tags) |tag, i| {
        const token = p.next();
        testing.expectEqual(tag, token.tag);
    }
    testing.expectEqual(Token.Tag.eof, p.next().tag);
    testing.expectEqual(text.len, p.index);
}

test "fences" {
    testTokenizer("```", &.{.fence});
    testTokenizer("~~~", &.{.fence});
    testTokenizer(":::", &.{.fence});
    testTokenizer(",,,", &.{.text});
}

test "language" {
    testTokenizer("```zig", &.{ .fence, .identifier });
}

test "definition" {
    testTokenizer("```{.zig #example}", &.{
        .fence,
        .l_brace,
        .dot,
        .identifier,
        .space,
        .hash,
        .identifier,
        .r_brace,
    });
}

test "inline" {
    testTokenizer("`code`{.zig #example}", &.{
        .fence,
        .identifier,
        .fence,
        .l_brace,
        .dot,
        .identifier,
        .space,
        .hash,
        .identifier,
        .r_brace,
    });
}

test "chevron" {
    testTokenizer("<<this-is-a-placeholder>>", &.{
        .l_chevron,
        .identifier,
        .r_chevron,
    });
}

test "caption" {
    testTokenizer(
        \\~~~{.zig caption="example"}
        \\some arbitrary text
        \\
        \\more
        \\~~~
    , &.{
        .fence,
        .l_brace,
        .dot,
        .identifier,
        .space,
        .identifier,
        .equal,
        .string,
        .r_brace,
        .newline,
        // newline
        // note: this entire block is what you would ignore in the parser until
        // you see the sequence .newline, .fence which either closes or opens a
        // code block. If there's no .l_brace then it can be ignored as it's not
        // a literate block. This is based on how entangled worked before 1.0
        .identifier,
        .space,
        .identifier,
        .space,
        .identifier,

        .newline,

        .newline,

        .identifier,
        // The sequence which terminates the block follows.
        .newline,

        .fence,
    });
}

const NodeList = std.MultiArrayList(Node);
const Node = struct {
    tag: Tag,
    token: Index,

    pub const Tag = enum(u8) {
        tag,
        filename,
        file,
        block,
        inline_block,
        placeholder,
        end,
    };
    pub const Index = u16;
};

const TokenIndex = struct { index: Node.Index };

const TokenList = struct {
    tag: Token.Tag,
    start: TokenIndex,
};

const Tokens = std.MultiArrayList(TokenList);

const RootIndex = struct { index: Node.Index };
const RootList = std.ArrayListUnmanaged(RootIndex);
const NameMap = std.StringHashMapUnmanaged(Node.Index);

const Parser = struct {
    text: []const u8,
    gpa: *Allocator,
    index: usize,
    tokens: Tokens.Slice,
    nodes: NodeList,
    roots: RootList,
    name_map: NameMap,

    const log = std.log.scoped(.parser);

    pub fn init(gpa: *Allocator, text: []const u8) !Parser {
        var tokens = Tokens{};

        var tokenizer: Tokenizer = .{ .text = text };

        while (tokenizer.index < text.len) {
            const token = tokenizer.next();
            try tokens.append(gpa, .{
                .tag = token.tag,
                .start = .{ .index = @intCast(Node.Index, token.data.start) },
            });
        }

        return Parser{
            .text = text,
            .tokens = tokens.toOwnedSlice(),
            .index = 0,
            .nodes = NodeList{},
            .name_map = NameMap{},
            .gpa = gpa,
            .roots = RootList{},
        };
    }

    pub fn deinit(p: *Parser) void {
        p.tokens.deinit(p.gpa);
        p.nodes.deinit(p.gpa);
        p.roots.deinit(p.gpa);
        p.name_map.deinit(p.gpa);
        p.* = undefined;
    }

    fn getToken(p: Parser, index: usize) !Token {
        const starts = p.tokens.items(.start);
        var tokenizer: Tokenizer = .{ .text = p.text, .index = starts[index].index };
        return tokenizer.next();
    }

    fn expect(p: *Parser, tag: Token.Tag) !void {
        defer p.index += 1;
        if (p.peek() != tag) {
            log.debug("expected {s} found {s}", .{ @tagName(tag), @tagName(p.peek().?) });
            return error.UnexpectedToken;
        }
        log.debug("expect  | {s}", .{@tagName(tag)});
    }

    fn get(p: *Parser, tag: Token.Tag) ![]const u8 {
        defer p.index += 1;
        if (p.peek() != tag) {
            log.debug("expected {s} found {s}", .{ @tagName(tag), @tagName(p.peek().?) });
            return error.UnexpectedToken;
        }
        const slice = p.getTokenSlice(p.index);
        log.debug("get     | {s} (( {s} ))", .{ @tagName(tag), slice });
        return slice;
    }

    fn getTokenSlice(p: Parser, index: usize) []const u8 {
        const token = try p.getToken(index);
        return p.text[token.data.start..token.data.end];
    }

    fn consume(p: *Parser) !Token.Tag {
        const token = p.peek() orelse return error.OutOfBounds;
        log.debug("consume | {s}", .{@tagName(token)});
        p.index += 1;
        return token;
    }

    fn peek(p: Parser) ?Token.Tag {
        const tokens = p.tokens.items(.tag);
        return if (p.index < p.tokens.len) tokens[p.index] else null;
    }

    pub fn resolve(p: *Parser) !void {
        while (p.findStartOfBlock()) |tag| {
            const node = switch (tag) {
                .inline_block => |start| try p.parseInlineBlock(start),
                .fenced_block => try p.parseFencedBlock(),
            };
            log.debug("          block {}", .{node});
            try p.addTagNames(node);
        }
    }

    fn addTagNames(p: *Parser, block: Node.Index) !void {
        const tags = p.nodes.items(.tag);
        const tokens = p.nodes.items(.token);

        {
            var i = block - 1;
            while (true) : (i -= 1) {
                switch (tags[i]) {
                    .filename => {},
                    .tag => {
                        const name = p.getTokenSlice(tokens[i]);
                        const result = try p.name_map.getOrPut(p.gpa, name);
                        if (result.found_existing) return error.NameConflict;
                        result.entry.value = block;
                    },
                    // no other type of node found above belongs to the given
                    // block thus this is a safe assumption
                    else => break,
                }

                if (i == 0) break;
            }
        }
    }

    fn parseFencedBlock(p: *Parser) !Node.Index {
        const tokens = p.tokens.items(.tag);
        const fence = (p.get(.fence) catch unreachable).len;
        log.debug("<< fenced block meta >>", .{});

        const reset = p.nodes.len;
        errdefer p.nodes.shrinkRetainingCapacity(reset);

        const filename = try p.parseMetaBlock();
        try p.expect(.newline);

        log.debug("<< fenced block start >>", .{});

        const block_start = p.index;

        // find the closing fence
        while (mem.indexOfPos(Token.Tag, tokens, p.index, &.{ .newline, .fence })) |found| {
            if (p.getTokenSlice(found + 1).len == fence) {
                p.index = found + 2;
                break;
            } else {
                p.index = found + 2;
            }
        } else return error.FenceNotClosed;

        const block_end = p.index - 2;

        var this: Node.Index = undefined;

        if (filename) |file| {
            try p.nodes.append(p.gpa, .{
                .tag = .filename,
                .token = file,
            });
            try p.roots.append(p.gpa, .{ .index = @intCast(Node.Index, p.nodes.len) });
            this = @intCast(Node.Index, p.nodes.len);
            try p.nodes.append(p.gpa, .{
                .tag = .file,
                .token = @intCast(Node.Index, block_start),
            });
        } else {
            this = @intCast(Node.Index, p.nodes.len);
            try p.nodes.append(p.gpa, .{
                .tag = .block,
                .token = @intCast(Node.Index, block_start),
            });
        }

        try p.parsePlaceholders(block_start, block_end);

        try p.nodes.append(p.gpa, .{
            .tag = .end,
            .token = @intCast(Node.Index, block_end),
        });

        p.index = block_end + 2;

        log.debug("<< fenced block end >>", .{});

        return this;
    }

    fn parsePlaceholders(p: *Parser, start: usize, end: usize) !void {
        const tokens = p.tokens.items(.tag);
        p.index = start;
        while (mem.indexOfPos(Token.Tag, tokens[0..end], p.index, &.{.l_chevron})) |found| {
            p.index = found + 1;
            log.debug("search  | {s}", .{@tagName(tokens[found])});
            const name = p.get(.identifier) catch continue;
            p.expect(.r_chevron) catch continue;

            log.debug(
                "          placeholder {} token {} (( {s} ))",
                .{ p.nodes.len, found + 1, name },
            );
            try p.nodes.append(p.gpa, .{
                .tag = .placeholder,
                .token = @intCast(Node.Index, found + 1),
            });
        }
    }

    fn parseInlineBlock(p: *Parser, start: usize) !Node.Index {
        const block_end = p.index;
        p.expect(.fence) catch unreachable;
        log.debug("<< inline block meta >>", .{});

        const reset = p.nodes.len;
        errdefer p.nodes.shrinkRetainingCapacity(reset);

        if ((try p.parseMetaBlock()) != null) return error.InlineFileBlock;
        log.debug("<< inline block start >>", .{});

        const this = @intCast(Node.Index, p.nodes.len);
        try p.nodes.append(p.gpa, .{
            .tag = .inline_block,
            .token = @intCast(Node.Index, start),
        });

        const end = p.index;
        defer p.index = end;

        try p.parsePlaceholders(start, block_end);

        try p.nodes.append(p.gpa, .{
            .tag = .end,
            .token = @intCast(Node.Index, block_end),
        });

        log.debug("<< inline block end >>", .{});

        return this;
    }

    /// Parse the metau data block which follows a fence and
    /// allocate nodes for each tag found.
    fn parseMetaBlock(p: *Parser) !?Node.Index {
        p.expect(.l_brace) catch unreachable;
        var file: ?Node.Index = null;

        try p.expect(.dot);
        const language = try p.get(.identifier);
        try p.expect(.space);

        const before = p.nodes.len;
        errdefer p.nodes.shrinkRetainingCapacity(before);

        while (true) {
            switch (try p.consume()) {
                .identifier => {
                    const key = p.getTokenSlice(p.index - 1);
                    try p.expect(.equal);
                    const string = try p.get(.string);
                    if (mem.eql(u8, "file", key)) {
                        if (file != null) return error.MultipleTargets;
                        if (string.len <= 2) return error.InvalidFileName;
                        file = @intCast(Node.Index, p.index - 3);
                    }
                },
                .hash => {
                    try p.expect(.identifier);
                    try p.nodes.append(p.gpa, .{
                        .tag = .tag,
                        .token = @intCast(Node.Index, p.index - 1),
                    });
                },
                .space => {},
                .r_brace => break,
                else => return error.InvalidMetaBlock,
            }
        }

        return file;
    }

    const Block = union(enum) {
        inline_block: usize,
        fenced_block,
    };

    /// Find the start of a fenced or inline code block
    fn findStartOfBlock(p: *Parser) ?Block {
        const tokens = p.tokens.items(.tag);
        const starts = p.tokens.items(.start);

        while (p.index < p.tokens.len) {
            // search for a multi-line/inline code block `{.z
            const block = mem.indexOfPos(Token.Tag, tokens, p.index, &.{
                .fence,
                .l_brace,
                .dot,
                .identifier,
            }) orelse return null;

            // figure out of this the real start
            const newline = mem.lastIndexOfScalar(Token.Tag, tokens[0..block], .newline) orelse 0;

            if (newline + 1 == block or newline == block) {
                // found fenced block

                var tokenizer: Tokenizer = .{ .text = p.text, .index = starts[block].index };
                const token = tokenizer.next();
                assert(token.tag == .fence);
                if (token.data.end - token.data.start >= 3) {
                    p.index = block;
                    return .fenced_block;
                } else {
                    // not a passable codeblock, skip it and keep searching
                    p.index = block + 1;
                }
            } else if (mem.indexOfScalarPos(Token.Tag, tokens[0..block], newline, .fence)) |start| {
                // found inline block TODO: fix for `` ` ``{.zig}

                if (start < block) {
                    // by the time we've verified the current block to be inline we've also
                    // found the start of the block thus we return the start to avoid
                    // searcing for it again
                    p.index = block;
                    return Block{ .inline_block = start };
                } else {
                    // not a passable codeblock, skip it and keep searching
                    p.index = block + 1;
                }
            }
        } else return null;
    }
};

const Tree = struct {
    text: []const u8,
    // TODO: you can probably remove this
    tokens: Tokens.Slice,
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

test "parse simple" {
    // TODO: more tests
    var tree = try Tree.parse(std.testing.allocator,
        \\This is an example file with some text that will
        \\cause the tokenizer to fill the token slice with
        \\garbage until the block below is reached.
        \\
        \\To make sure sequences with strings that "span
        \\multiple lines" are handled it's placed here.
        \\
        \\```{.this file="is.ok" #and-can-have-tags}
        \\code follows which will again generage garbage
        \\however! <<this-block-is-not>> and some of the
        \\<<code-that-follows-like-this>> will be spliced
        \\in later.
        \\```
        \\
        \\The rest of the file isn't really interesting
        \\other than ``one `<<inline>>``{.block #that}
        \\shows up.
        \\
        \\```
        \\this is a block the parser won't will pick up
        \\```
        \\
        \\```{.while #this}
        \\will be picked up
        \\```
    );
    defer tree.deinit(std.testing.allocator);

    const root = tree.roots[0];
    const tags = tree.tokens.items(.tag);
    const node_tokens = tree.nodes.items(.token);

    testing.expectEqual(root.index, tree.name_map.get("and-can-have-tags").?);
    testing.expectEqual(Token.Tag.l_chevron, tags[node_tokens[root.index + 1] - 1]);
    testing.expectEqual(Token.Tag.l_chevron, tags[node_tokens[root.index + 2] - 1]);
    testing.expectEqual(root.index + 5, tree.name_map.get("that").?);
}

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
