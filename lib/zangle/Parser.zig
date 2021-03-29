const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");

const Parser = @This();

pub const NodeList = std.MultiArrayList(Node);
pub const Node = struct {
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

pub const TokenIndex = struct { index: Node.Index };

pub const Token = struct {
    tag: Tokenizer.Token.Tag,
    start: TokenIndex,
};

pub const TokenList = std.MultiArrayList(Token);

pub const RootIndex = struct { index: Node.Index };
pub const RootList = std.ArrayListUnmanaged(RootIndex);
pub const NameMap = std.StringHashMapUnmanaged(Node.Index);

text: []const u8,
gpa: *Allocator,
index: usize,
tokens: TokenList.Slice,
nodes: NodeList,
roots: RootList,
name_map: NameMap,

const log = std.log.scoped(.parser);

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

fn getToken(p: Parser, index: usize) !Tokenizer.Token {
    const starts = p.tokens.items(.start);
    var tokenizer: Tokenizer = .{ .text = p.text, .index = starts[index].index };
    return tokenizer.next();
}

fn expect(p: *Parser, tag: Tokenizer.Token.Tag) !void {
    defer p.index += 1;
    if (p.peek() != tag) {
        log.debug("expected {s} found {s}", .{ @tagName(tag), @tagName(p.peek().?) });
        return error.UnexpectedToken;
    }
    log.debug("expect  | {s}", .{@tagName(tag)});
}

fn get(p: *Parser, tag: Tokenizer.Token.Tag) ![]const u8 {
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

fn consume(p: *Parser) !Tokenizer.Token.Tag {
    const token = p.peek() orelse return error.OutOfBounds;
    log.debug("consume | {s}", .{@tagName(token)});
    p.index += 1;
    return token;
}

fn peek(p: Parser) ?Tokenizer.Token.Tag {
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
    while (mem.indexOfPos(Tokenizer.Token.Tag, tokens, p.index, &.{ .newline, .fence })) |found| {
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
    while (mem.indexOfPos(Tokenizer.Token.Tag, tokens[0..end], p.index, &.{.l_chevron})) |found| {
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
                return Block{ .inline_block = start };
            } else {
                // not a passable codeblock, skip it and keep searching
                p.index = block + 1;
            }
        }
    } else return null;
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
