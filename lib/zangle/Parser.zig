const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const Tokenizer = @import("Tokenizer.zig");

const Parser = @This();

pub const Indent = u16;
pub const NodeList = std.MultiArrayList(Node);
pub const Node = struct {
    tag: Tag,
    token: Index,
    data: Index,

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

pub const TokenIndex = struct { index: Node.Index };

pub const Token = struct {
    tag: Tokenizer.Token.Tag,
    start: TokenIndex,
};

pub const TokenList = std.MultiArrayList(Token);

pub const DocTest = struct { index: Node.Index };
pub const DocTestList = ArrayListUnmanaged(DocTest);
pub const RootIndex = struct { index: Node.Index };
pub const RootList = ArrayListUnmanaged(RootIndex);
pub const NameMap = std.StringHashMapUnmanaged(Name);
pub const Name = struct { head: Node.Index, trail: Trail };
pub const Trail = ArrayListUnmanaged(Node.Index);
pub const Delimiter = enum {
    /// Treat delimiters the same as regular text
    ignore,
    chevron,
    brace,
};

text: []const u8,
gpa: *Allocator,
index: usize,
tokens: TokenList.Slice,
nodes: NodeList,
roots: RootList,
name_map: NameMap,
doctests: DocTestList,
delimiter: Delimiter = .chevron,

pub fn init(gpa: *Allocator, text: []const u8) !Parser {
    var tokens = TokenList{};

    var tok: Tokenizer = .{ .text = text };

    while (tok.index < text.len) {
        const token = tok.next();
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
        .doctests = DocTestList{},
        .gpa = gpa,
        .roots = RootList{},
    };
}

pub fn deinit(p: *Parser) void {
    p.tokens.deinit(p.gpa);
    p.nodes.deinit(p.gpa);
    p.roots.deinit(p.gpa);
    p.doctests.deinit(p.gpa);
    p.name_map.deinit(p.gpa);
    p.* = undefined;
}

fn getToken(p: Parser, index: usize) !Tokenizer.Token {
    const starts = p.tokens.items(.start);
    var tokenizer: Tokenizer = .{ .text = p.text, .index = starts[index].index };
    return tokenizer.next();
}

fn expect(p: *Parser, tag: Tokenizer.Token.Tag) !void {
    defer p.index += 1;
    if (p.peek() != tag) {
        return error.UnexpectedToken;
    }
}

fn get(p: *Parser, tag: Tokenizer.Token.Tag) ![]const u8 {
    defer p.index += 1;
    if (p.peek() != tag) {
        return error.UnexpectedToken;
    }
    const slice = p.getTokenSlice(p.index);
    return slice;
}

fn getTokenSlice(p: Parser, index: usize) []const u8 {
    const token = try p.getToken(index);
    return p.text[token.data.start..token.data.end];
}

fn consume(p: *Parser) !Tokenizer.Token.Tag {
    const token = p.peek() orelse return error.OutOfBounds;
    p.index += 1;
    return token;
}

fn peek(p: Parser) ?Tokenizer.Token.Tag {
    const tokens = p.tokens.items(.tag);
    return if (p.index < p.tokens.len) tokens[p.index] else null;
}

pub fn resolve(p: *Parser) !void {
    while (p.findStartOfBlock()) |tag| {
        const delimiter = p.delimiter;
        const node = switch (tag) {
            .inline_block => |start| try p.parseInlineBlock(start),
            .fenced_block => try p.parseFencedBlock(),
        };
        p.delimiter = delimiter;
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
                    if (result.found_existing) {
                        try result.entry.value.trail.append(p.gpa, block);
                    } else {
                        result.entry.value = .{
                            .head = block,
                            .trail = Trail{},
                        };
                    }
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
    const fence = p.get(.fence) catch unreachable;

    const reset = p.nodes.len;
    errdefer p.nodes.shrinkRetainingCapacity(reset);

    const info = try p.parseMetaBlock();

    const block_start = p.index + 1;

    // find the closing fence
    while (mem.indexOfPos(Tokenizer.Token.Tag, tokens, p.index, &.{ .newline, .fence })) |found| {
        if (mem.eql(u8, fence, p.getTokenSlice(found + 1))) {
            p.index = found + 1;
            break;
        } else {
            p.index = found + 1;
        }
    } else return error.FenceNotClosed;

    const block_end = p.index;

    var this: Node.Index = undefined;

    if (info.filename) |file| {
        try p.nodes.append(p.gpa, .{
            .tag = .filename,
            .token = file,
            .data = undefined,
        });
        try p.roots.append(p.gpa, .{ .index = @intCast(Node.Index, p.nodes.len) });
        this = @intCast(Node.Index, p.nodes.len);
        try p.nodes.append(p.gpa, .{
            .tag = .file,
            .token = @intCast(Node.Index, block_start),
            .data = undefined,
        });
    } else {
        this = @intCast(Node.Index, p.nodes.len);
        try p.nodes.append(p.gpa, .{
            .tag = .block,
            .token = @intCast(Node.Index, block_start),
            .data = undefined,
        });
    }

    if (info.doctest) {
        try p.doctests.append(p.gpa, .{ .index = this });
    }

    try p.parsePlaceholders(block_start, block_end, true);

    try p.nodes.append(p.gpa, .{
        .tag = .end,
        .token = @intCast(Node.Index, block_end),
        .data = undefined,
    });

    p.index = block_end + 2;

    return this;
}

fn parseInlineBlock(p: *Parser, start: usize) !Node.Index {
    const block_end = p.index;
    p.expect(.fence) catch unreachable;

    const reset = p.nodes.len;
    errdefer p.nodes.shrinkRetainingCapacity(reset);

    const info = try p.parseMetaBlock();
    if (info.filename != null) return error.InlineFileBlock;
    if (info.doctest) return error.InlineDocTest;

    const this = @intCast(Node.Index, p.nodes.len);
    try p.nodes.append(p.gpa, .{
        .tag = .inline_block,
        .token = @intCast(Node.Index, start - 1),
        .data = undefined,
    });

    const end = p.index;
    defer p.index = end;

    try p.parsePlaceholders(start, block_end, false);

    try p.nodes.append(p.gpa, .{
        .tag = .end,
        .token = @intCast(Node.Index, block_end),
        .data = undefined,
    });

    return this;
}

const Meta = struct {
    filename: ?Node.Index,
    doctest: bool,
};

/// Parse the meta data block which follows a fence and
/// allocate nodes for each tag found.
fn parseMetaBlock(p: *Parser) !Meta {
    p.expect(.l_brace) catch unreachable;
    var file: ?Node.Index = null;
    var doctest = false;

    try p.expect(.dot);
    const language = try p.get(.identifier);
    try p.expect(.space);

    const before = p.nodes.len;
    errdefer p.nodes.shrinkRetainingCapacity(before);

    while (true) {
        switch (try p.consume()) {
            .dot => {
                const key = try p.get(.identifier);
                if (mem.eql(u8, "doctest", key)) {
                    doctest = true;
                } else {
                    // Ignore it, it's probably for pandoc or another filter
                }
            },

            .identifier => {
                const key = p.getTokenSlice(p.index - 1);
                try p.expect(.equal);
                const string = try p.get(.string);
                if (mem.eql(u8, "file", key)) {
                    if (file != null) return error.MultipleTargets;
                    if (string.len <= 2) return error.InvalidFileName;
                    file = @intCast(Node.Index, p.index - 1);
                } else if (mem.eql(u8, "delimiter", key)) {
                    p.delimiter = meta.stringToEnum(Delimiter, string) orelse
                        return error.InvalidDelimiter;
                }
            },

            .hash => {
                try p.expect(.identifier);
                try p.nodes.append(p.gpa, .{
                    .tag = .tag,
                    .token = @intCast(Node.Index, p.index - 1),
                    .data = undefined,
                });
            },

            .space => {},
            .r_brace => break,
            else => return error.InvalidMetaBlock,
        }
    }

    return Meta{ .filename = file, .doctest = doctest };
}

fn parsePlaceholders(p: *Parser, start: usize, end: usize, block: bool) !void {
    const tokens = p.tokens.items(.tag);
    const starts = p.tokens.items(.start);
    p.index = start;
    var last = p.index;
    while (mem.indexOfPos(Tokenizer.Token.Tag, tokens[0..end], p.index, &.{.l_chevron})) |found| {
        p.index = found + 1;
        const name = p.get(.identifier) catch continue;
        const chev = p.get(.r_chevron) catch continue;

        switch (p.delimiter) {
            .ignore => continue,
            .chevron => if (!mem.eql(u8, ">>", chev)) continue,
            .brace => if (!mem.eql(u8, "}}", chev)) continue,
        }

        const newline = if (block)
            (mem.lastIndexOfScalar(Tokenizer.Token.Tag, tokens[0..found], .newline) orelse 0)
        else
            found;

        const indent = p.text[starts[newline + 1].index..starts[found].index].len;

        try p.nodes.append(p.gpa, .{
            .tag = .placeholder,
            .token = @intCast(Node.Index, found + 1),
            .data = @intCast(Indent, indent),
        });
    }
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
        const block = mem.indexOfPos(Tokenizer.Token.Tag, tokens, p.index, &.{
            .fence,
            .l_brace,
            .dot,
            .identifier,
        }) orelse return null;

        // figure out of this the real start
        const newline = mem.lastIndexOfScalar(Tokenizer.Token.Tag, tokens[0..block], .newline) orelse 0;

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
        } else if (mem.indexOfScalarPos(Tokenizer.Token.Tag, tokens[0..block], newline, .fence)) |start| {
            // found inline block TODO: fix for `` ` ``{.zig}

            if (start < block) {
                // by the time we've verified the current block to be inline we've also
                // found the start of the block thus we return the start to avoid
                // searcing for it again
                p.index = block;
                return Block{ .inline_block = start + 2 };
            } else {
                // not a passable codeblock, skip it and keep searching
                p.index = block + 1;
            }
        }
    } else return null;
}

fn testParse(input: []const u8) !void {
    var p = try Parser.init(std.testing.allocator, input);
    try p.resolve();
    defer p.deinit();
}

test "parse simple" {
    // TODO: more tests
    var p = try Parser.init(std.testing.allocator,
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
    try p.resolve();
    defer p.deinit();

    const root = p.roots.items[0];
    const tags = p.tokens.items(.tag);
    const node_tokens = p.nodes.items(.token);

    testing.expectEqual(root.index, p.name_map.get("and-can-have-tags").?);
    testing.expectEqual(Tokenizer.Token.Tag.l_chevron, tags[node_tokens[root.index + 1] - 1]);
    testing.expectEqual(Tokenizer.Token.Tag.l_chevron, tags[node_tokens[root.index + 2] - 1]);
    testing.expectEqual(root.index + 5, p.name_map.get("that").?);
}

test "fences" {
    try testParse(
        \\```{.zig file="render.zig"}
        \\```
    );

    try testParse(
        \\```{.zig file="render.zig"}
        \\const <<tree-type>> = struct {};
        \\// A
        \\```
        \\
        \\```{.zig file="parse.zig"}
        \\const <<tree-type>> = struct {};
        \\```
    );
}
