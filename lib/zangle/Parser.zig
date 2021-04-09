const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const math = std.math;
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ComptimeStringMap = std.ComptimeStringMap;

const Tokenizer = @import("Tokenizer.zig");

const Parser = @This();

pub const Indent = u16;
pub const NodeList = std.MultiArrayList(Node);
pub const Node = struct {
    tag: Tag,
    token: Index,
    data: Index,

    pub const BlockData = packed struct {
        file: bool = false,
        inline_block: bool = false,
        inline_content: bool = false,
        pad: u13 = 0,

        pub fn cast(data: Index) callconv(.Inline) BlockData {
            return @bitCast(BlockData, data);
        }

        pub fn int(self: BlockData) callconv(.Inline) Index {
            return @bitCast(Index, self);
        }
    };

    comptime {
        assert(@sizeOf(BlockData) == @sizeOf(Index));
    }

    pub const Tag = enum(u8) {
        tag,
        filename,
        type,
        block,
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
pub const Name = struct { head: Node.Index, tail: Tail };
pub const Tail = ArrayListUnmanaged(Node.Index);

pub const Delimiter = enum {
    //! Delimiter - the delimiter used for the current block being parsed.

    /// Treat delimiters the same as regular text
    none,
    chevron,
    brace,
    paren,
    bracket,
};

pub const Error = struct {
    code: SyntaxError,
    token: Tokenizer.Token,

    pub const ErrorConfig = struct {
        colour: bool = true,
        show_line: bool = true,
    };

    pub fn describe(
        e: Error,
        text: []const u8,
        config: ErrorConfig,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        var line: usize = 0;
        var col: usize = 0;
        var line_start: usize = 0;
        const start = e.token.data.start;
        const end = e.token.data.end;

        for (text[0..start]) |byte, i| {
            if (byte == '\n') {
                line += 1;
                col = 0;
                line_start = i + 1;
            } else {
                col += 1;
            }
        }

        try writer.print("error on line {} col {}: ", .{ line + 1, col + 1 });
        switch (e.code) {
            .unexpected_token => |expected| {
                try writer.print("unexpected token `{s}'", .{@tagName(e.token.tag)});
                if (expected) |tag| try writer.print(" expected `{s}'", .{@tagName(tag)});
            },
            .out_of_bounds => try writer.writeAll("unexpected end of file"),
            .fence_not_closed => try writer.writeAll("unclosed fence"),
            .inline_file_block => try writer.writeAll("inline blocks cannot declare files"),
            .inline_doctest => try writer.writeAll("inline blocks cannot declare doctests"),
            .illegal_byte_in_string => |byte| try writer.print("illegal byte `{}' found in string", .{byte}),
            .multiple_file_targets => |m| try writer.print(
                "block declares another target file `{s}' in addition to the existing target",
                .{m},
            ),
            .empty_filename => try writer.writeAll("filenames may not be empty"),
            .invalid_delimiter => |d| try writer.print("`{s}' is not a valid delimiter", .{d}),
            .invalid_meta_block => try writer.writeAll("metadata block is not correctly formed"),
            .unknown_filter => |s| try writer.print("`{s}' is not a known filter type", .{s}),
            .type_error => |t| try writer.print("`{s}' does not match the expected type `{s}'", .{
                t.got,
                t.expect,
            }),
        }

        try writer.writeByte('\n');

        if (config.show_line) {
            try writer.writeAll(text[line_start..start]);
            if (config.colour) try writer.writeAll("\x1b[31m");
            try writer.writeAll(text[start..end]);
            if (config.colour) try writer.writeAll("\x1b[0m");

            var tail: usize = end;
            for (text[end..]) |byte| {
                if (byte == '\n' or byte == '\r') break;
                tail += 1;
            }

            try writer.print("{s}\n", .{text[end..tail]});
            try writer.writeByteNTimes(' ', start - line_start);
            if (config.colour) try writer.writeAll("\x1b[31m");
            try writer.writeByte('^');
            try writer.writeByteNTimes('~', math.sub(usize, e.token.len(), 1) catch 0);
            if (config.colour) try writer.writeAll("\x1b[0m");
            try writer.writeByte('\n');
        }
    }
};

pub const ErrorList = ArrayListUnmanaged(Error);
pub const SyntaxError = union(enum) {
    unexpected_token: ?Tokenizer.Token.Tag,
    out_of_bounds,
    fence_not_closed,
    inline_file_block,
    inline_doctest,
    illegal_byte_in_string: u8,
    multiple_file_targets: []const u8,
    empty_filename,
    invalid_delimiter: []const u8,
    invalid_meta_block,
    unknown_filter,
    type_error: struct { expect: []const u8, got: []const u8 },
};

fn testErrorString(e: Error, config: Error.ErrorConfig, text: []const u8, expected: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try e.describe(text, config, fbs.writer());
    testing.expectEqualStrings(expected, fbs.getWritten());
}

test "error display" {
    // TODO: real test of errors on files
    const text =
        \\some text with an error to find on the next line
        \\which is This one
        \\and not here.
        \\
    ;
    const err = mem.indexOf(u8, text, "This").?;
    const token: Tokenizer.Token = .{
        .tag = .invalid,
        .data = .{
            .start = err,
            .end = err + 4,
        },
    };

    try testErrorString(.{ .code = .{ .unexpected_token = null }, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: unexpected token `invalid'
        \\which is This one
        \\         ^~~~
        \\
    );
    try testErrorString(.{ .code = .{ .unexpected_token = .newline }, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: unexpected token `invalid' expected `newline'
        \\which is This one
        \\         ^~~~
        \\
    );
    try testErrorString(.{ .code = .out_of_bounds, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: unexpected end of file
        \\which is This one
        \\         ^~~~
        \\
    );
    try testErrorString(.{ .code = .fence_not_closed, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: unclosed fence
        \\which is This one
        \\         ^~~~
        \\
    );
    try testErrorString(.{ .code = .inline_file_block, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: inline blocks cannot declare files
        \\which is This one
        \\         ^~~~
        \\
    );
    try testErrorString(.{ .code = .inline_doctest, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: inline blocks cannot declare doctests
        \\which is This one
        \\         ^~~~
        \\
    );
    try testErrorString(.{ .code = .{ .illegal_byte_in_string = 'f' }, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: illegal byte `102' found in string
        \\which is This one
        \\         ^~~~
        \\
    );
    try testErrorString(.{ .code = .{ .multiple_file_targets = "This" }, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: block declares another target file `This' in addition to the existing target
        \\which is This one
        \\         ^~~~
        \\
    );
    try testErrorString(.{ .code = .empty_filename, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: filenames may not be empty
        \\which is This one
        \\         ^~~~
        \\
    );
    try testErrorString(.{ .code = .{ .invalid_delimiter = "This" }, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: `This' is not a valid delimiter
        \\which is This one
        \\         ^~~~
        \\
    );
    try testErrorString(.{ .code = .invalid_meta_block, .token = token }, .{ .colour = false }, text,
        \\error on line 2 col 10: metadata block is not correctly formed
        \\which is This one
        \\         ^~~~
        \\
    );
}

/// Slice of the original markdown document.
text: []const u8,

gpa: *Allocator,

/// Parser index into the token list. After parsing, this value is no longer
/// used.
index: usize,

tokens: TokenList.Slice,

nodes: NodeList,

roots: RootList,

/// Mapping of placeholder names to nodes within the document.
name_map: NameMap,

doctests: DocTestList,

/// delimiter - This can be set to avoid clashes between the meta and object
/// language or even to `none` to ignore delimiters completely.
delimiter: Delimiter = .chevron,

errors: ErrorList,

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
        .errors = ErrorList{},
    };
}

pub fn deinit(p: *Parser) void {
    p.tokens.deinit(p.gpa);
    p.nodes.deinit(p.gpa);
    p.roots.deinit(p.gpa);
    p.doctests.deinit(p.gpa);
    var it = p.name_map.iterator();
    while (it.next()) |entry| entry.value.tail.deinit(p.gpa);
    p.name_map.deinit(p.gpa);
    p.* = undefined;
}

fn getToken(p: Parser, index: usize) Tokenizer.Token {
    const starts = p.tokens.items(.start);
    var tokenizer: Tokenizer = .{ .text = p.text, .index = starts[index].index };
    return tokenizer.next();
}

fn expect(p: *Parser, tag: Tokenizer.Token.Tag) !void {
    defer p.index += 1;
    if (p.peek() != tag) {
        try p.errors.append(p.gpa, .{
            .code = .{ .unexpected_token = tag },
            .token = p.getToken(p.index),
        });
        return error.UnexpectedToken;
    }
}

fn get(p: *Parser, tag: Tokenizer.Token.Tag) ![]const u8 {
    defer p.index += 1;
    if (p.peek() != tag) {
        try p.errors.append(p.gpa, .{
            .code = .{ .unexpected_token = tag },
            .token = p.getToken(p.index),
        });
        return error.UnexpectedToken;
    }
    const slice = p.getTokenSlice(p.index);
    return slice;
}

fn getTokenSlice(p: Parser, index: usize) []const u8 {
    const token = p.getToken(index);
    return token.slice(p.text);
}

fn consume(p: *Parser) !Tokenizer.Token.Tag {
    const token = p.peek() orelse {
        try p.errors.append(p.gpa, .{
            .code = .out_of_bounds,
            .token = p.getToken(p.index),
        });
        return error.OutOfBounds;
    };
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

pub fn typeCheck(p: *Parser) !void {
    const tags = p.nodes.items(.tag);
    const tokens = p.nodes.items(.token);
    var block_type: []const u8 = undefined;
    var err = false;
    for (tags) |tag, i| switch (tag) {
        .type => block_type = p.getTokenSlice(tokens[i]),
        .placeholder => {
            const placeholder = p.getTokenSlice(tokens[i]);
            const node = p.name_map.get(placeholder) orelse {
                err = true;
                continue;
            };

            const Pair = struct { type: []const u8, token: Tokenizer.Token };

            const node_type = p.getTokenSlice(tokens[node.head - 1]);
            const colon = p.getTokenSlice(tokens[i] + 1);
            if (mem.eql(u8, ":", colon)) {
                const pair: Pair = blk: {
                    if (p.getToken(tokens[i] + 3).tag == .l_paren) {
                        // get the defined cast type
                        const index = tokens[i] + 4;
                        break :blk .{
                            .type = p.getTokenSlice(index),
                            .token = p.getToken(index),
                        };
                    } else {
                        // get the explicit type
                        const index = tokens[i] + 2;
                        break :blk .{
                            .type = p.getTokenSlice(index),
                            .token = p.getToken(index),
                        };
                    }
                };

                if (!mem.eql(u8, node_type, pair.type)) {
                    err = true;
                    try p.errors.append(p.gpa, .{
                        .code = .{ .type_error = .{ .expect = node_type, .got = pair.type } },
                        .token = pair.token,
                    });
                }
            } else {
                if (!mem.eql(u8, block_type, node_type)) {
                    err = true;
                    try p.errors.append(p.gpa, .{
                        .code = .{ .type_error = .{ .expect = block_type, .got = node_type } },
                        .token = p.getToken(tokens[i]),
                    });
                }
            }
        },
        else => {},
    };

    if (err) return error.TypeCheckFailed;
}

/// Scan above the current block for placeholders and add this node to the
/// respective placeholders' node list.
fn addTagNames(p: *Parser, block: Node.Index) !void {
    const tags = p.nodes.items(.tag);
    const tokens = p.nodes.items(.token);

    if (block == 0) return;

    {
        var i = block - 1;
        while (true) : (i -= 1) {
            switch (tags[i]) {
                .type, .filename => {},
                .tag => {
                    const name = p.getTokenSlice(tokens[i]);
                    const result = try p.name_map.getOrPut(p.gpa, name);
                    if (result.found_existing) {
                        try result.entry.value.tail.append(p.gpa, block);
                    } else {
                        result.entry.value = .{
                            .head = block,
                            .tail = Tail{},
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
    const fence_pos = p.index;
    const fence = p.get(.fence) catch unreachable;

    const reset = p.nodes.len;
    errdefer p.nodes.shrinkRetainingCapacity(reset);

    const info = try p.parseMetaBlock();

    const block_start = p.index + 1;

    // find the closing fence
    while (mem.indexOfPos(Tokenizer.Token.Tag, tokens, p.index, &.{ .newline, .fence })) |found| {
        if (mem.eql(u8, fence, p.getTokenSlice(found + 1))) {
            p.index = found;
            break;
        } else {
            p.index = found + 2;
        }
    } else {
        try p.errors.append(p.gpa, .{
            .code = .fence_not_closed,
            .token = p.getToken(fence_pos),
        });
        return error.FenceNotClosed;
    }

    const block_end = p.index;

    var this: Node.Index = undefined;

    if (info.filename) |file| {
        try p.nodes.append(p.gpa, .{
            .tag = .filename,
            .token = file,
            .data = undefined,
        });

        try p.nodes.append(p.gpa, .{
            .tag = .type,
            .token = info.type,
            .data = undefined,
        });

        try p.roots.append(p.gpa, .{ .index = @intCast(Node.Index, p.nodes.len) });

        this = @intCast(Node.Index, p.nodes.len);

        try p.nodes.append(p.gpa, .{
            .tag = .block,
            .token = @intCast(Node.Index, block_start),
            .data = (Node.BlockData{
                .file = true,
                .inline_content = info.inline_content,
            }).int(),
        });
    } else {
        try p.nodes.append(p.gpa, .{
            .tag = .type,
            .token = info.type,
            .data = undefined,
        });

        this = @intCast(Node.Index, p.nodes.len);

        try p.nodes.append(p.gpa, .{
            .tag = .block,
            .token = @intCast(Node.Index, block_start),
            .data = (Node.BlockData{
                .inline_content = info.inline_content,
            }).int(),
        });
    }

    if (info.doctest != null) {
        try p.doctests.append(p.gpa, .{ .index = this });
    }

    try p.parsePlaceholders(block_start, block_end, true);

    try p.nodes.append(p.gpa, .{
        .tag = .end,
        .token = @intCast(Node.Index, block_end + 1),
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

    var err = false;

    if (info.filename) |node| {
        try p.errors.append(p.gpa, .{
            .code = .inline_file_block,
            .token = p.getToken(node),
        });
        err = true;
    }

    if (info.doctest) |node| {
        try p.errors.append(p.gpa, .{
            .code = .inline_doctest,
            .token = p.getToken(node),
        });
        err = true;
    }

    if (err) return error.InvalidInlineBlock;

    try p.nodes.append(p.gpa, .{
        .tag = .type,
        .token = info.type,
        .data = undefined,
    });

    const this = @intCast(Node.Index, p.nodes.len);
    try p.nodes.append(p.gpa, .{
        .tag = .block,
        .token = @intCast(Node.Index, start - 1),
        .data = (Node.BlockData{
            .inline_block = true,
            .inline_content = true,
        }).int(),
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

/// Parse a string literal.
fn parseString(p: *Parser) ![]const u8 {
    const start = p.getToken(p.index).data.start;

    while (true) switch (try p.consume()) {
        .newline => {
            try p.errors.append(p.gpa, .{
                .code = .{ .illegal_byte_in_string = '\n' },
                .token = p.getToken(p.index - 1),
            });
            return error.IllegalByteInString;
        },
        .string => return p.text[start .. p.getToken(p.index).data.start - 1],
        else => {
            // allow other tokens
        },
    };
}

fn parseFilename(p: *Parser) ![]const u8 {
    switch (try p.consume()) {
        .string => return try p.parseString(),
        .identifier, .forward_slash, .backward_slash => {
            const start = p.getToken(p.index - 1);
            while (true) {
                const next = p.peek() orelse return error.UnexpectedEof;
                switch (next) {
                    .newline => {
                        _ = p.consume() catch unreachable;
                        try p.errors.append(p.gpa, .{
                            .code = .{ .illegal_byte_in_string = '\n' },
                            .token = p.getToken(p.index),
                        });
                        return error.IllegalByteInString;
                    },
                    .space => {
                        _ = p.consume() catch unreachable;
                        const end = p.getToken(p.index);
                        return p.text[start.data.start..end.data.start];
                    },
                    .r_brace => {
                        const end = p.getToken(p.index);
                        return p.text[start.data.start..end.data.start];
                    },
                    else => _ = try p.consume(),
                }
            }
        },
        else => {
            return error.InvalidFilename;
        },
    }
}

const Meta = struct {
    filename: ?Node.Index,
    doctest: ?Node.Index,
    inline_content: bool,
    type: Node.Index,
};

/// Parse the meta data block which follows a fence and
/// allocate nodes for each tag found.
fn parseMetaBlock(p: *Parser) !Meta {
    switch (p.consume() catch unreachable) {
        .space => assert(p.consume() catch unreachable == .l_brace),
        .l_brace => {},
        else => unreachable,
    }

    try p.expect(.dot);
    try p.expect(.identifier);

    var meta_block = Meta{
        .filename = null,
        .doctest = null,
        .type = @intCast(Node.Index, p.index - 1),
        .inline_content = false,
    };

    switch (try p.consume()) {
        .space => {},
        .r_brace => return meta_block,
        else => {
            try p.errors.append(p.gpa, .{
                .code = .{ .unexpected_token = null },
                .token = p.getToken(p.index - 1),
            });
            return error.UnexpectedToken;
        },
    }

    const before = p.nodes.len;
    errdefer p.nodes.shrinkRetainingCapacity(before);

    while (true) {
        switch (try p.consume()) {
            .dot => {
                const key = try p.get(.identifier);
                if (mem.eql(u8, "doctest", key)) {
                    meta_block.doctest = @intCast(Node.Index, p.index - 1);
                } else if (mem.eql(u8, "inline", key)) {
                    meta_block.inline_content = true;
                } else if (mem.eql(u8, "docrun", key)) {
                    // TODO
                } else {
                    // Ignore it, it's probably for pandoc or another filter
                }
            },

            .identifier => {
                const key = p.getTokenSlice(p.index - 1);
                try p.expect(.equal);
                const stridx = p.index;
                const string = try p.parseFilename();
                if (mem.eql(u8, "file", key)) {
                    if (meta_block.filename != null) {
                        try p.errors.append(p.gpa, .{
                            .code = .{ .multiple_file_targets = string },
                            .token = p.getToken(stridx),
                        });
                        return error.MultipleFileTargets;
                    }

                    if (string.len == 0) {
                        try p.errors.append(p.gpa, .{
                            .code = .empty_filename,
                            .token = p.getToken(stridx),
                        });
                        return error.EmptyFilename;
                    }

                    meta_block.filename = @intCast(Node.Index, stridx);
                } else if (mem.eql(u8, "delimiter", key)) {
                    p.delimiter = meta.stringToEnum(Delimiter, string) orelse {
                        try p.errors.append(p.gpa, .{
                            .code = .{ .invalid_delimiter = string },
                            .token = p.getToken(stridx - 2),
                        });

                        return error.InvalidDelimiter;
                    };
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
            else => {
                try p.errors.append(p.gpa, .{
                    .code = .invalid_meta_block,
                    .token = p.getToken(p.index - 1),
                });

                return error.InvalidMetaBlock;
            },
        }
    }

    return meta_block;
}

const Filter = enum { shell, escape };
const EscapeFilter = enum { zig_string, python_string, html };

const builtin_filters = ComptimeStringMap(Filter, .{
    .{ "shell", .shell },
    .{ "escape", .escape },
});

const escape_filters = ComptimeStringMap(EscapeFilter, .{
    .{ "zig-string", .zig_string },
    .{ "python-string", .python_string },
    .{ "html", .html },
});

fn parseFilter(p: *Parser) !void {
    const filter = builtin_filters.get(try p.get(.identifier)) orelse {
        return error.UnknownFilter;
    };

    switch (filter) {
        .escape, .shell => |tag| {
            const space = try p.get(.space);
            const option = try p.get(.identifier);
            switch (tag) {
                .escape => _ = escape_filters.get(option) orelse {
                    try p.errors.append(p.gpa, .{
                        .code = .unknown_filter,
                        .token = p.getToken(p.index - 1),
                    });
                    return error.UnknownEscapeFilter;
                },
                .shell => {},
            }
        },
    }
}

fn parseTypeSignature(p: *Parser) !void {
    const explicit_type = try p.consume();
    if (explicit_type != .identifier) {
        try p.errors.append(p.gpa, .{
            .code = .{ .unexpected_token = .identifier },
            .token = p.getToken(p.index - 1),
        });
        return error.InvalidTypeSignature;
    }

    if (!mem.eql(u8, "from", p.getTokenSlice(p.index - 1))) return;

    if ((try p.consume()) != .l_paren) {
        try p.errors.append(p.gpa, .{
            .code = .{ .unexpected_token = .l_paren },
            .token = p.getToken(p.index - 1),
        });
        return error.InvalidTypeSignature;
    }

    const cast_type = try p.get(.identifier);

    try p.expect(.r_paren);
}

fn parsePlaceholders(p: *Parser, start: usize, end: usize, block: bool) !void {
    const tokens = p.tokens.items(.tag);
    const starts = p.tokens.items(.start);
    p.index = start;
    var last = p.index;
    while (mem.indexOfPos(Tokenizer.Token.Tag, tokens[0..end], p.index, &.{.l_chevron})) |found| {
        p.index = found + 1;
        const chevron = p.index - 1;
        const chev = p.getTokenSlice(chevron);

        switch (p.delimiter) {
            .none => continue,
            .chevron => if (!mem.eql(u8, "<<", chev)) continue,
            .brace => if (!mem.eql(u8, "{{", chev)) continue,
            .paren => if (!mem.eql(u8, "((", chev)) continue,
            .bracket => if (!mem.eql(u8, "[[", chev)) continue,
        }

        const name = p.get(.identifier) catch continue;

        switch (try p.consume()) {
            .r_chevron => {},
            .pipe => try p.parseFilter(),
            .fence => {
                const fence = p.getTokenSlice(p.index - 1);
                if (fence.len == 1 and fence[0] == ':') {
                    try p.parseTypeSignature();

                    const pipe = p.peek();
                    if (pipe != null and pipe.? == .pipe) {
                        p.expect(.pipe) catch unreachable;
                        try p.parseFilter();
                    }
                    try p.expect(.r_chevron);
                } else continue;
            },
            else => continue,
        }

        var indent: usize = 0;

        if (mem.lastIndexOfScalar(Tokenizer.Token.Tag, tokens[0..chevron], .newline)) |nl| {
            const here = p.getToken(chevron);
            const newline = p.getToken(nl);
            indent = here.data.start - newline.data.end;
        }

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
    // TODO: fix infinite loop when `{.z is in a code block

    while (p.index < p.tokens.len) {
        // search for a multi-line/inline code block `{.z
        const nospace = &.{ .fence, .l_brace, .dot, .identifier };
        const spaced = &.{ .fence, .space, .l_brace, .dot, .identifier };
        const block = mem.indexOfPos(Tokenizer.Token.Tag, tokens, p.index, nospace) orelse
            mem.indexOfPos(Tokenizer.Token.Tag, tokens, p.index, spaced) orelse
            return null;

        // figure out of this the real start
        const newline = mem.lastIndexOfScalar(Tokenizer.Token.Tag, tokens[0..block], .newline) orelse 0;

        if (newline + 1 == block or newline == block) {
            // found fenced block

            var tokenizer: Tokenizer = .{ .text = p.text, .index = starts[block].index };
            const token = tokenizer.next();
            assert(token.tag == .fence);
            if (token.len() >= 3) {
                p.index = block;
                return .fenced_block;
            } else {
                // not a passable codeblock, skip it and keep searching
                p.index = block + 1;
            }
        } else {
            // found inline block
            const fence = p.getTokenSlice(block);
            assert(p.getToken(block).tag == .fence);
            var backtrack: usize = block;
            while (true) {
                const start = mem.lastIndexOfScalar(Tokenizer.Token.Tag, tokens[0..backtrack], .fence) orelse {
                    p.index = block - 1;
                    break;
                };
                if (mem.eql(u8, fence, p.getTokenSlice(start))) {
                    // by the time we've verified the current block to be inline we've also
                    // found the start of the block thus we return the start to avoid
                    // searcing for it again
                    p.index = block;
                    return Block{ .inline_block = start + 2 };
                } else {
                    // not a passable codeblock, skip it and keep searching
                    backtrack = start;
                }
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

    testing.expectEqual(root.index, p.name_map.get("and-can-have-tags").?.head);
    testing.expectEqual(Tokenizer.Token.Tag.l_chevron, tags[node_tokens[root.index + 1] - 1]);
    testing.expectEqual(Tokenizer.Token.Tag.l_chevron, tags[node_tokens[root.index + 2] - 1]);
    testing.expectEqual(root.index + 6, p.name_map.get("that").?.head);
}

test "parse fences" {
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

test "parse placeholders" {
    try testParse(
        \\```{.zig #a}
        \\<<a>>
        \\```
    );

    try testParse(
        \\```{.zig #a}
        \\<<a:a>>
        \\```
    );

    try testParse(
        \\```{.zig #a}
        \\<<a|escape zig-string>>
        \\```
    );

    try testParse(
        \\```{.zig #a}
        \\<<a:a|escape zig-string>>
        \\```
    );

    try testParse(
        \\```{.zig #a}
        \\<<a:from(a)>>
        \\```
    );

    try testParse(
        \\```{.zig #a}
        \\<<a:from(a)|escape zig-string>>
        \\```
    );
}

test "parse files" {
    try testParse(
        \\```{.zig file="a.zig"}
        \\```
    );

    try testParse(
        \\```{.zig file=a.zig}
        \\```
    );
}
