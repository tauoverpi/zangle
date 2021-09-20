# Zangle

Zangle is a literate programming tool for extracting code fragments from
markdown and other types of text documents into separate files ready for
compilation.

    lang: zig esc: none tag: #main
    ------------------------------

    pub fn main() anyerror!void {
        var instance = std.heap.GeneralPurposeAllocator(.{}){};
        const gpa = &instance.allocator;

        const args = os.argv;

        var vm: Interpreter = .{};

        // options
        var allow_absolute_paths = false;
        var allow_shell_filters = false;
        var omit_trailing_newline = false;
        // end options

        for (args[1..]) |arg0| {
            const arg = mem.sliceTo(arg0, 0);

            if (mem.eql(u8, arg, "--allow-absolute-paths")) {
                allow_absolute_paths = true;
            } else if (mem.eql(u8, arg, "--allow-shell-filters")) {
                allow_shell_filters = true;
            } else if (mem.eql(u8, arg, "--omit-trailing-newline")) {
                omit_trailing_newline = true;
            } else {
                const text = try fs.cwd().readFileAlloc(gpa, arg, 0x7fff_ffff);
                const object = try Parser.parse(gpa, text);
                vm.linker.objects.append(gpa, object) catch return error.@"Exhausted memory";
            }
        }

        try vm.linker.link(gpa);

        for (vm.linker.files.keys()) |key| {
            std.log.debug("writing file: {s}", .{key});

            if (key[0] == '/' and !allow_absolute_paths) {
                return error.@"Absolute paths disabled; use --allow-absolute-paths to enable them.";
            }

            if (fs.path.dirname(key)) |dir| try fs.cwd().makePath(dir);

            var file = try fs.cwd().createFile(key, .{ .truncate = true });
            defer file.close();

            var render = Render.init(file.writer());

            try vm.callFile(gpa, key, *Render, &render);
            if (!omit_trailing_newline) try render.stream.writer().writeByte('\n');
            try render.stream.flush();
        }
    }

.

    lang: zig esc: none tag: #main
    ------------------------------

    const Render = struct {
        stream: Stream,

        pub const Stream = io.BufferedWriter(1024, std.fs.File.Writer);

        pub fn init(writer: fs.File.Writer) Render {
            return .{ .stream = .{ .unbuffered_writer = writer } };
        }

        pub fn write(self: *Render, text: []const u8, index: u32, nl: u16) !void {
            _ = index;
            const writer = self.stream.writer();
            try writer.writeAll(text);
            try writer.writeByteNTimes('\n', nl);
        }

        pub fn indent(self: *Render, len: u16) !void {
            const writer = self.stream.writer();
            try writer.writeByteNTimes(' ', len);
        }
    };

# Machine

Zangle represents documents as bytecode programs consisting mostly of `write`
instructions to render code line-by-line with respect to the tag's indentation
along with block writes for weaving literate source documents. Other
instructions handle the order in which to tangle blocks of code such as
`call` which embeds one block in another and `jmp` which threads adjacent
blocks (by tag name) together into one.

## Instructions

Each instruction consists of an 8-bit opcode along with a 64-bit data argument.

### Ret

Pops the location and module in which the matching `call` instruction
originated from. If any filters have been registered in the calling context
then this instruction marks the end of the context and executes the action
bound.

    lang: zig esc: none tag: #instruction list
    ------------------------------------------

    pub const Ret = u64;


<!-- -->

    lang: zig esc: none tag: #parser codegen
    ----------------------------------------

    fn emitRet(
        p: *Parser,
        gpa: *Allocator,
    ) !void {
        log.debug("emitting ret", .{});
        try p.obj.program.append(gpa, .{
            .opcode = .ret,
            .data = .{ .ret = 0xffff_ffff },
        });
    }

### Jmp

Jumps to the specified address of the given module without pushing to the
return stack. This instruction is primarily used to thread blocks with the
same tag together across files in the order in which they occur within the
literate source. If the target module is 0 then it's interpreted as being
local to the current module.

    lang: zig esc: none tag: #instruction list
    ------------------------------------------

    pub const Jmp = extern struct {
        address: u32,
        module: u16,
        generation: u16 = 0,
    };

<!-- -->

    lang: zig esc: none tag: #parser codegen
    ----------------------------------------

    fn writeJmp(
        p: *Parser,
        location: u32,
        params: Instruction.Data.Jmp,
    ) !void {
        log.debug("writing jmp over {x:0>8} to {x:0>8}", .{
            location,
            params.address,
        });
        p.obj.program.set(location, .{
            .opcode = .jmp,
            .data = .{ .jmp = params },
        });
    }



### Call

Saves the module context, instruction pointer, and calling context on the
return stack before jumping to the specified address within the given module.
If the target module is 0 then it's interpreted as being local to the
current module.

    lang: zig esc: none tag: #instruction list
    ------------------------------------------

    pub const Call = extern struct {
        address: u32,
        module: u16,
        indent: u16,
    };

<!-- -->

    lang: zig esc: none tag: #parser codegen
    ----------------------------------------

    fn emitCall(
        p: *Parser,
        gpa: *Allocator,
        tag: []const u8,
        params: Instruction.Data.Call,
    ) !void {
        log.debug("emitting call to {s}", .{tag});
        const result = try p.obj.symbols.getOrPut(gpa, tag);
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        }

        try result.value_ptr.append(gpa, @intCast(u32, p.obj.program.len));

        try p.obj.program.append(gpa, .{
            .opcode = .call,
            .data = .{ .call = params },
        });
    }

### Shell

Appends a calling context to the next `call` instruction with a shell command
for filtering rendered content within the given block.

    lang: zig esc: none tag: #instruction list
    ------------------------------------------

    pub const Shell = extern struct {
        command: u32,
        module: u16,
        len: u8,
        pad: u8,
    };


<!-- -->

    lang: zig esc: none tag: #parser codegen
    ----------------------------------------

    fn emitShell(
        p: *Parser,
        gpa: *Allocator,
        params: Instruction.Data.Shell,
    ) !void {
        log.debug("emitting shell command", .{});
        try p.obj.program.append(gpa, .{
            .opcode = .shell,
            .data = .{ .shell = params },
        });
    }

### Write

Writes lines of text from the current module to the output stream. If a
calling context is present then the output is written to a buffer instead.
A trail of newline characters is emitted after the text as specified in the
`nl` field of the 64-bit data block.

    lang: zig esc: none tag: #instruction list
    ------------------------------------------

    pub const Write = extern struct {
        start: u32,
        len: u16,
        nl: u16,
    };

<!-- -->
<!-- -->

    lang: zig esc: none tag: #parser codegen
    ----------------------------------------

    fn emitWrite(
        p: *Parser,
        gpa: *Allocator,
        params: Instruction.Data.Write,
    ) !void {
        log.debug("emitting write {x:0>8} len {d} nl {d}", .{
            params.start,
            params.len,
            params.nl,
        });
        try p.obj.program.append(gpa, .{
            .opcode = .write,
            .data = .{ .write = params },
        });
    }

Instructions

    lang: zig esc: [[]] tag: #bytecode
    ----------------------------------

    opcode: Opcode,
    data: Data,

    pub const List = MultiArrayList(Instruction);
    pub const Opcode = enum(u8) {
        ret,
        call,
        jmp,
        shell,
        write,
    };

    pub const Data = extern union {
        ret: Ret,
        jmp: Jmp,
        call: Call,
        shell: Shell,
        write: Write,

        [[instruction list]]
    };

    comptime {
        assert(@sizeOf(Data) == 8);
    }

# Interpreters

Rendering is handled by passing interpreters

## Test interpreter

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    const Test = struct {
        stream: Stream,

        pub const Stream = std.io.FixedBufferStream([]u8);

        pub fn write(self: *Test, text: []const u8, index: u32, nl: u16) !void {
            _ = index;
            const writer = self.stream.writer();
            try writer.writeAll(text);
            try writer.writeByteNTimes('\n', nl);
        }

        pub fn indent(self: *Test, len: u16) !void {
            const writer = self.stream.writer();
            try writer.writeByteNTimes(' ', len);
        }

        pub fn expect(self: *Test, expected: []const u8) !void {
            try testing.expectEqualStrings(expected, self.stream.getWritten());
        }
    };

    const TestTangleOutput = struct {
        name: []const u8,
        text: []const u8,
    };

    fn testTangle(source: []const []const u8, output: []const TestTangleOutput) !void {
        var owned = true;
        var l: Linker = .{};
        defer if (owned) l.deinit(testing.allocator);

        for (source) |src| {
            const obj = try Parser.parse(testing.allocator, src);
            try l.objects.append(testing.allocator, obj);
        }

        try l.link(testing.allocator);

        var vm: Interpreter = .{ .linker = l };
        defer vm.deinit(testing.allocator);
        owned = false;

        errdefer for (l.objects.items) |obj, i| {
            log.debug("module {d}", .{i + 1});
            for (obj.program.items(.opcode)) |op| {
                log.debug("{}", .{op});
            }
        };

        for (output) |out| {
            log.debug("evaluating {s}", .{out.name});
            var buffer: [4096]u8 = undefined;
            var context: Test = .{ .stream = .{ .buffer = &buffer, .pos = 0 } };
            try vm.call(testing.allocator, out.name, *Test, &context);
            try context.expect(out.text);
        }
    }

    test "run simple no calls" {
        try testTangle(&.{
            \\begin
            \\
            \\    lang: zig esc: none tag: #foo
            \\    -----------------------------
            \\
            \\    abc
            \\
            \\end
        }, &.{
            .{ .name = "foo", .text = "abc" },
        });
    }

    test "run multiple outputs no calls" {
        try testTangle(&.{
            \\begin
            \\
            \\    lang: zig esc: none tag: #foo
            \\    -----------------------------
            \\
            \\    abc
            \\
            \\then
            \\
            \\    lang: zig esc: none tag: #bar
            \\    -----------------------------
            \\
            \\    123
            \\
            \\end
        }, &.{
            .{ .name = "foo", .text = "abc" },
            .{ .name = "bar", .text = "123" },
        });
    }

    test "run multiple outputs common call" {
        try testTangle(&.{
            \\begin
            \\
            \\    lang: zig esc: [[]] tag: #foo
            \\    -----------------------------
            \\
            \\    [[baz]]
            \\
            \\then
            \\
            \\    lang: zig esc: [[]] tag: #bar
            \\    -----------------------------
            \\
            \\    [[baz]][[baz]]
            \\
            \\then
            \\
            \\    lang: zig esc: none tag: #baz
            \\    -----------------------------
            \\
            \\    abc
            \\
            \\end
        }, &.{
            .{ .name = "baz", .text = "abc" },
            .{ .name = "bar", .text = "abcabc" },
            .{ .name = "foo", .text = "abc" },
        });
    }

    test "run multiple outputs multiple inputs" {
        try testTangle(&.{
            \\begin
            \\
            \\    lang: zig esc: [[]] tag: #foo
            \\    -----------------------------
            \\
            \\    [[baz]]
            \\
            \\end
        ,
            \\begin
            \\
            \\    lang: zig esc: [[]] tag: #bar
            \\    -----------------------------
            \\
            \\    [[baz]][[baz]]
            \\
            \\begin
        ,
            \\end
            \\
            \\    lang: zig esc: none tag: #baz
            \\    -----------------------------
            \\
            \\    abc
            \\
            \\end
        }, &.{
            .{ .name = "baz", .text = "abc" },
            .{ .name = "bar", .text = "abcabc" },
            .{ .name = "foo", .text = "abc" },
        });

    }


<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    pub fn deinit(vm: *Interpreter, gpa: *Allocator) void {
        vm.linker.deinit(gpa);
        vm.stack.deinit(gpa);
    }

    pub fn call(vm: *Interpreter, gpa: *Allocator, symbol: []const u8, comptime T: type, eval: T) !void {
        if (vm.linker.procedures.get(symbol)) |sym| {
            vm.ip = sym.entry;
            vm.module = sym.module;
            vm.indent = 0;
            log.debug("calling {s} address {x:0>8} module {d}", .{ symbol, vm.ip, vm.module });
            while (try vm.step(gpa, T, eval)) {}
        } else return error.@"Unknown procedure";
    }

    pub fn callFile(vm: *Interpreter, gpa: *Allocator, symbol: []const u8, comptime T: type, eval: T) !void {
        if (vm.linker.files.get(symbol)) |sym| {
            vm.ip = sym.entry;
            vm.module = sym.module;
            vm.indent = 0;
            log.debug("calling {s} address {x:0>8} module {d}", .{ symbol, vm.ip, vm.module });
            while (try vm.step(gpa, T, eval)) {}
        } else return error.@"Unknown procedure";
    }

<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    linker: Linker = .{},
    module: u16 = 1,
    ip: u32 = 0,
    stack: Stack = .{},
    indent: u16 = 0,
    should_indent: bool = false,
    last_is_newline: bool = true,

    const Stack = HashMap(u32, StackFrame);

    const StackFrame = struct {
        module: u16,
        ip: u32,
        indent: u16,
    };

    const log = std.log.scoped(.vm);

    pub fn step(vm: *Interpreter, gpa: *Allocator, comptime T: type, eval: T) !bool {
        const object = vm.linker.objects.items[vm.module - 1];
        const opcode = object.program.items(.opcode);
        const data = object.program.items(.data);
        const index = vm.ip;

        vm.ip += 1;

        switch (opcode[index]) {
            .ret => return vm.execRet(T, eval),
            .jmp => try vm.execJmp(T, data[index].jmp, eval),
            .call => try vm.execCall(T, data[index].call, gpa, eval),
            .shell => vm.execShell(T, data[index].shell, object.text, eval),
            .write => try vm.execWrite(T, data[index].write, object.text, eval),
        }

        return true;
    }

<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    fn execRet(vm: *Interpreter, comptime T: type, eval: T) bool {
        if (vm.stack.popOrNull()) |location| {
            const mod = vm.module;
            const ip = vm.ip;

            vm.ip = location.value.ip;
            vm.module = location.value.module;
            vm.indent -= location.value.indent;

            if (@hasDecl(meta.Child(T), "ret")) try eval.ret(vm.ip, vm.module, vm.indent);
            log.debug("[mod {d} ip {x:0>8}] ret(mod {d}, ip {x:0>8})", .{
                mod,
                ip,
                vm.module,
                vm.ip,
            });

            return true;
        }

        if (@hasDecl(meta.Child(T), "terminate")) try eval.terminate();
        log.debug("[mod {d} ip {x:0>8}] terminate()", .{
            vm.module,
            vm.ip,
        });

        return false;
    }

<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    fn execJmp(vm: *Interpreter, comptime T: type, data: Instruction.Data.Jmp, eval: T) !void {
        const mod = vm.module;
        const ip = vm.ip;

        if (data.module != 0) {
            vm.module = data.module;
        }

        vm.ip = data.address;

        if (@hasDecl(meta.Child(T), "jmp")) try eval.jmp(vm.ip, data.address);
        if (@hasDecl(meta.Child(T), "write")) try eval.write("\n", 0, 0);

        log.debug("[mod {d} ip {x:0>8}] jmp(mod {d}, address {x:0>8})", .{
            mod,
            ip,
            vm.module,
            vm.ip,
        });

        vm.last_is_newline = true;
    }

<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    fn execCall(vm: *Interpreter, comptime T: type, data: Instruction.Data.Call, gpa: *Allocator, eval: T) !void {
        if (vm.stack.contains(vm.ip)) {
            return error.@"Cyclic reference detected";
        }

        const mod = vm.module;
        const ip = vm.ip;

        try vm.stack.put(gpa, vm.ip, .{
            .ip = vm.ip,
            .indent = data.indent,
            .module = vm.module,
        });

        vm.indent += data.indent;
        vm.ip = data.address;

        if (data.module != 0) {
            vm.module = data.module;
        }

        if (@hasDecl(meta.Child(T), "call")) try eval.call(vm.ip, vm.module, vm.indent);
        log.debug("[mod {d} ip {x:0>8}] call(mod {d}, ip {x:0>8})", .{
            mod,
            ip - 1,
            vm.module,
            vm.ip,
        });
    }

<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    fn execShell(
        vm: *Interpreter,
        comptime T: type,
        data: Instruction.Data.Shell,
        text: []const u8,
        eval: T,
    ) void {
        if (@hasDecl(meta.Child(T), "shell")) try eval.shell();
        _ = vm;
        _ = data;
        _ = text;
        @panic("TODO: implement shell");
    }

<!-- -->

    lang: zig esc: none tag: #interpreter step
    ------------------------------------------

    fn execWrite(
        vm: *Interpreter,
        comptime T: type,
        data: Instruction.Data.Write,
        text: []const u8,
        eval: T,
    ) !void {
        if (vm.should_indent and vm.last_is_newline) {
            if (@hasDecl(meta.Child(T), "indent")) try eval.indent(vm.indent);
            log.debug("[mod {d} ip {x:0>8}] indent(len {d})", .{
                vm.module,
                vm.ip,
                vm.indent,
            });
        } else {
            vm.should_indent = true;
        }

        if (@hasDecl(meta.Child(T), "write")) try eval.write(
            text[data.start..data.start + data.len],
            data.start,
            data.nl,
        );

        log.debug("[mod {d} ip {x:0>8}] write(text {*}, index {x:0>8}, len {d}, nl {d}): {s}", .{
            vm.module,
            vm.ip,
            text,
            data.start,
            data.len,
            data.nl,
            text[data.start .. data.start + data.len],
        });

        vm.last_is_newline = data.nl != 0;
    }

# Linker

    lang: zig esc: none tag: #linker
    --------------------------------

    objects: Object.List = .{},
    generation: u16 = 1,
    procedures: ProcedureMap = .{},
    files: FileMap = .{},

    const ProcedureMap = StringMap(Procedure);
    const FileMap = StringMap(Procedure);
    const Procedure = struct {
        entry: u32,
        module: u16,
    };


    const log = std.log.scoped(.linker);

    pub fn deinit(l: *Linker, gpa: *Allocator) void {
        for (l.objects.items) |*obj| obj.deinit(gpa);
        l.objects.deinit(gpa);
        l.procedures.deinit(gpa);
        l.files.deinit(gpa);
        l.generation = undefined;
    }

    pub const Object = struct {
        text: []const u8,
        program: Instruction.List = .{},
        symbols: SymbolMap = .{},
        adjacent: AdjacentMap = .{},
        files: Object.FileMap = .{},

        pub const List = ArrayList(Object);
        pub const SymbolMap = StringMap(SymbolList);
        pub const FileMap = StringMap(u32);
        pub const SymbolList = ArrayList(u32);
        pub const AdjacentMap = StringMap(Adjacent);

        pub const Adjacent = struct {
            entry: u32,
            exit: u32,
        };

        pub fn deinit(self: *Object, gpa: *Allocator) void {
            self.program.deinit(gpa);

            for (self.symbols.values()) |*entry| entry.deinit(gpa);
            self.symbols.deinit(gpa);
            self.adjacent.deinit(gpa);
            self.files.deinit(gpa);
        }
    };

### Merge adjacent blocks

TODO: short-circuit on non local module end

    lang: zig esc: none tag: #linker
    --------------------------------

    fn mergeAdjacent(l: *Linker) void {
        for (l.objects.items) |*obj, module| {
            log.debug("processing module {d}", .{ module + 1 });
            const values = obj.adjacent.values();
            for (obj.adjacent.keys()) |key, i| {
                const opcodes = obj.program.items(.opcode);
                const data = obj.program.items(.data);
                const exit = values[i].exit;
                log.debug("opcode {}", .{opcodes[exit]});

                switch (opcodes[exit]) {
                    .ret, .jmp => {
                        if (opcodes[exit] == .jmp and data[exit].jmp.generation == l.generation) continue;
                        var last_adj = values[i];
                        var last_obj = obj;

                        for (l.objects.items[module + 1..]) |*next, offset| {
                            if (next.adjacent.get(key)) |current| {
                                const op = last_obj.program.items(.opcode)[last_adj.exit];
                                assert(op == .jmp or op == .ret);

                                const destination = @intCast(u16, module + offset) + 2;
                                log.debug("updating jump location to address 0x{x:0>8} in module {d}", .{
                                    current.entry,
                                    destination,
                                });

                                last_obj.program.items(.opcode)[last_adj.exit] = .jmp;
                                last_obj.program.items(.data)[last_adj.exit] = .{ .jmp = .{
                                    .generation = l.generation,
                                    .address = current.entry,
                                    .module = destination,
                                } };
                                last_adj = current;
                                last_obj = next;
                            }
                        }
                    },

                    else => unreachable,
                }
            }
        }
    }

    test "merge" {
        var obj_a = try Parser.parse(testing.allocator,
            \\
            \\
            \\    lang: zig esc: none tag: #a
            \\    ---------------------------
            \\
            \\    abc
            \\
            \\end
            \\
            \\    lang: zig esc: none tag: #b
            \\    ---------------------------
            \\
            \\    abc
            \\
            \\end
        );

        var obj_b = try Parser.parse(testing.allocator,
            \\
            \\
            \\    lang: zig esc: none tag: #a
            \\    ---------------------------
            \\
            \\    abc
            \\
            \\end
        );

        var obj_c = try Parser.parse(testing.allocator,
            \\
            \\
            \\    lang: zig esc: none tag: #b
            \\    ---------------------------
            \\
            \\    abc
            \\
            \\end
        );

        var l: Linker = .{};
        defer l.deinit(testing.allocator);

        try l.objects.appendSlice(testing.allocator, &.{
            obj_a,
            obj_b,
            obj_c,
        });

        l.mergeAdjacent();

        try testing.expectEqualSlices(Instruction.Opcode, &.{ .write, .jmp, .write, .jmp }, obj_a.program.items(.opcode));

        try testing.expectEqual(
            Instruction.Data.Jmp{
                .module = 2,
                .address = 0,
                .generation = 1,
            },
            obj_a.program.items(.data)[1].jmp,
        );

        try testing.expectEqual(
            Instruction.Data.Jmp{
                .module = 3,
                .address = 0,
                .generation = 1,
            },
            obj_a.program.items(.data)[3].jmp,
        );
    }

### Register procedures

    lang: zig esc: none tag: #linker
    --------------------------------

    fn buildProcedureTable(l: *Linker, gpa: *Allocator) !void {
        log.debug("building procedure table", .{});
        for (l.objects.items) |obj, module| {
            log.debug("processing module {d} with {d} procedures", .{ module + 1, obj.adjacent.keys().len });
            for (obj.adjacent.keys()) |key, i| {
                const entry = try l.procedures.getOrPut(gpa, key);
                if (!entry.found_existing) {
                    const entry_point = obj.adjacent.values()[i].entry;
                    log.debug("registering new procedure '{s}' address {x:0>8} module {d}", .{ key, entry_point, module + 1 });

                    entry.value_ptr.* = .{
                        .module = @intCast(u16, module) + 1,
                        .entry = @intCast(u32, entry_point),
                    };
                }
            }
        }
        log.debug("registered {d} procedures", .{l.procedures.count()});
    }

### Update procedure calls

    lang: zig esc: none tag: #linker
    --------------------------------

    fn updateProcedureCalls(l: *Linker) void {
        log.debug("updating procedure calls", .{});
        for (l.procedures.keys()) |key, i| {
            const proc = l.procedures.values()[i];
            for (l.objects.items) |*obj| if (obj.symbols.get(key)) |sym| {
                log.debug("updating locations {any}", .{sym.items});
                for (sym.items) |location| {
                    assert(obj.program.items(.opcode)[location] == .call);
                    const call = &obj.program.items(.data)[location].call;
                    call.address = proc.entry;
                    call.module = proc.module;
                }
            };
        }
    }

### Check for file conflicts and build a file table

    lang: zig esc: none tag: #linker
    --------------------------------

    fn buildFileTable(l: *Linker, gpa: *Allocator) !void {
        for (l.objects.items) |obj, module| {
            for (obj.files.keys()) |key, i| {
                const file = try l.files.getOrPut(gpa, key);
                if (file.found_existing) return error.@"Multiple files with the same name";
                file.value_ptr.module = @intCast(u16, module) + 1;
                file.value_ptr.entry = obj.files.values()[i];
            }
        }
    }

### Link

    lang: zig esc: none tag: #linker
    --------------------------------

    pub fn link(l: *Linker, gpa: *Allocator) !void {
        l.procedures.clearRetainingCapacity();
        l.files.clearRetainingCapacity();

        try l.buildProcedureTable(gpa);
        try l.buildFileTable(gpa);

        l.mergeAdjacent();
        l.updateProcedureCalls();

        var failure = false;
        for (l.objects.items) |obj| {
            for (obj.symbols.keys()) |key| {
                if (!l.procedures.contains(key)) {
                    failure = true;
                    log.err("unknown symbol '{s}'", .{key});
                }
            }
        }

        if (failure) return error.@"Unknown symbol";
    }


    test "call" {
        var obj = try Parser.parse(testing.allocator,
            \\
            \\
            \\    lang: zig esc: none tag: #a
            \\    ---------------------------
            \\
            \\    abc
            \\
            \\end
            \\
            \\    lang: zig esc: [[]] tag: #b
            \\    ---------------------------
            \\
            \\    [[a]]
            \\
            \\end
        );

        var l: Linker = .{};
        defer l.deinit(testing.allocator);

        try l.objects.append(testing.allocator, obj);
        try l.link(testing.allocator);

        try testing.expectEqualSlices(
            Instruction.Opcode,
            &.{ .write, .ret, .call, .ret },
            obj.program.items(.opcode),
        );

        try testing.expectEqual(
            Instruction.Data.Call{
                .address = 0,
                .module = 1,
                .indent = 0,
            },
            obj.program.items(.data)[2].call,
        );
    }

### Update call-sites

Each call is updated with the correct entry point (address and module) for the

# Format

The default syntax consists of blocks indented by 4 spaces.

## Parser

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

    it: Tokenizer,
    obj: Linker.Object,

    const Token = Tokenizer.Token;
    const log = std.log.scoped(.parser);

### Token

    lang: zig esc: none tag: #zangle tokenizer token
    ------------------------------------------------

    pub const Token = struct {
        tag: Tag,
        start: usize,
        end: usize,

        pub const Tag = enum(u8) {
            eof,

            nl = '\n',
            space = ' ',

            word,
            line = '-',
            hash = '#',
            pipe = '|',
            colon = ':',

            l_angle   = '<',
            l_brace   = '{',
            l_bracket = '[',
            l_paren   = '(',

            r_angle   = '>',
            r_brace   = '}',
            r_bracket = ']',
            r_paren   = ')',

            unknown,
        };

        pub fn slice(t: Token, bytes: []const u8) []const u8 {
            return bytes[t.start..t.end];
        }

        pub fn len(t: Token) usize {
            return t.end - t.start;
        }
    };

### Tokenizer

    lang: zig esc: [[]] tag: #zangle tokenizer
    ------------------------------------------

    bytes: []const u8,
    index: usize = 0,

    const log = std.log.scoped(.tokenizer);

    [[zangle tokenizer token]]

    pub fn next(self: *Tokenizer) Token {
        var token: Token = .{
            .tag = .eof,
            .start = self.index,
            .end = undefined,
        };

        defer log.debug("{s: >10} {d: >3} | {s}", .{
            @tagName(token.tag),
            token.len(),
            token.slice(self.bytes),
        });

        const State = enum { start, trivial, unknown, word };
        var state: State = .start;
        var trivial: u8 = 0;

        while (self.index < self.bytes.len) : (self.index += 1) {
            const c = self.bytes[self.index];
            switch (state) {
                .trivial => if (c != trivial) break,
                .start => switch (c) {
                    [[zangle tokenizer start transitions]]
                },

                [[zangle tokenizer state transitions]]
            }
        }

        token.end = self.index;
        return token;
    }

    [[zangle tokenizer tests]]

#### Whitespace

Whitespace of the same type is consumed as a single token.

    lang: zig esc: none tag: #zangle tokenizer start transitions
    ------------------------------------------------------------

    ' ', '\n' => {
        token.tag = @intToEnum(Token.Tag, c);
        trivial = c;
        state = .trivial;
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer tests
    ------------------------------------------------

    test "tokenize whitespace" {
        try testTokenize("\n", &.{.nl});
        try testTokenize(" ", &.{.space});
        try testTokenize("\n\n\n\n\n", &.{.nl});
        try testTokenize("\n\n     \n\n\n", &.{.nl, .space, .nl});
    }

#### Header

    lang: zig esc: none tag: #zangle tokenizer start transitions
    ------------------------------------------------------------

    '-' => {
        token.tag = .line;
        trivial = '-';
        state = .trivial;
    },

    'a'...'z' => {
        token.tag = .word;
        state = .word;
    },

    '#', ':' => {
        token.tag = @intToEnum(Token.Tag, c);
        self.index += 1;
        break;
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer state transitions
    ------------------------------------------------------------

    .word => switch (c) {
        'a'...'z', 'A'...'Z', '#', '+', '-', '\'', '_' => {},
        else => break,
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer tests
    ------------------------------------------------

    test "tokenize header" {
        try testTokenize("-", &.{.line});
        try testTokenize("#", &.{.hash});
        try testTokenize(":", &.{.colon});
        try testTokenize("-----------------", &.{.line});
        try testTokenize("###", &.{.hash, .hash, .hash});
        try testTokenize(":::", &.{.colon, .colon, .colon});
    }

#### Include

    lang: zig esc: none tag: #zangle tokenizer start transitions
    ------------------------------------------------------------

    '<', '{', '[', '(', ')', ']', '}', '>' => {
        token.tag = @intToEnum(Token.Tag, c);
        trivial = c;
        state = .trivial;
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer start transitions
    ------------------------------------------------------------

    '|' => {
        token.tag = .pipe;
        self.index += 1;
        break;
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer tests
    ------------------------------------------------

    test "tokenize include" {
        try testTokenize("|", &.{.pipe});
        try testTokenize("|||", &.{.pipe, .pipe, .pipe});
    }

#### Unknown

    lang: zig esc: none tag: #zangle tokenizer start transitions
    ------------------------------------------------------------

    else => {
        token.tag = .unknown;
        state = .unknown;
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer state transitions
    ------------------------------------------------------------

    .unknown => if (mem.indexOfScalar(u8, "\n <{[()]}>:|", c)) |_| {
        break;
    },

<!-- -->

    lang: zig esc: none tag: #zangle tokenizer tests
    ------------------------------------------------

    test "tokenize unknown" {
        try testTokenize("/file.example/path/../__", &.{.unknown});
    }

### Header

Each code block starts with a header specifying the language used, delimiters
for code block imports, and either a file in which the content should be
written to or a tag which may be referenced with import statements.

TODO: record statistisc on the number of tag occurences so it's possible to
display `Tag: example tag (5/16)`.

TODO: link same tags together so they form a chain and a loop back to the
start at the end. This allows the user to click through to the next block.

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

    const Header = struct {
        language: []const u8,
        delimiter: ?[]const u8,
        resource: []const u8,
        type: Type,

        pub const Type = enum { file, tag };
    };

    const ParseHeaderError = error {
        @"Expected a space between 'lang:' and the language name",
        @"Expected a space after the language name",
        @"Expected a space between 'esc:' and the delimiter specification",
        @"Expected open delimiter",
        @"Expected closing delimiter",
        @"Expected matching closing angle bracket '>'",
        @"Expected matching closing brace '}'",
        @"Expected matching closing bracket ']'",
        @"Expected matching closing paren ')'",
        @"Expected opening and closing delimiter lengths to match",
        @"Expected a space after delimiter specification",
        @"Expected 'tag:' or 'file:' following delimiter specification",
        @"Expected a space after 'file:'",
        @"Expected a space after 'tag:'",
        @"Expected a newline after the header",
        @"Expected the dividing line to be indented by 4 spaces",
        @"Expected a dividing line of '-' of the same length as the header",
        @"Expected the division line to be of the same length as the header",
        @"Expected at least one blank line after the division line",
        @"Expected there to be only one space but more were given",

        @"Missing language specification",
        @"Missing ':' after 'lang'",
        @"Missing language name",
        @"Missing 'esc:' delimiter specification",
        @"Missing ':' after 'esc'",
        @"Missing ':' after 'file'",
        @"Missing ':' after 'tag'",
        @"Missing '#' after 'tag: '",
        @"Missing file name",
        @"Missing tag name",

        @"Invalid delimiter, expected one of '<', '{', '[', '('",
        @"Invalid delimiter, expected one of '>', '}', ']', ')'",
        @"Invalid option given, expected 'tag:' or 'file:'",
    };

    fn parseHeaderLine(p: *Parser) ParseHeaderError!Header {
        var header: Header = undefined;

        const header_start = p.it.index;
        p.match(.word, "lang") orelse return error.@"Missing language specification";
        p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'lang'";

        if (p.eat(.space, @src())) |space| {
            if (space.len != 1) return error.@"Expected there to be only one space but more were given";
        } else {
            return error.@"Expected a space between 'lang:' and the language name";
        }

        header.language = p.eat(.word, @src()) orelse return error.@"Missing language name";
        p.expect(.space, @src()) orelse return error.@"Expected a space after the language name";
        p.match(.word, "esc") orelse return error.@"Missing 'esc:' delimiter specification";
        p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'esc'";

        if (p.eat(.space, @src())) |space| {
            if (space.len != 1) return error.@"Expected there to be only one space but more were given";
        } else {
            return error.@"Expected a space between 'esc:' and the delimiter specification";
        }

        if (p.match(.word, "none") == null) {
            const start = p.it.index;
            const open = p.next() orelse return error.@"Expected open delimiter";

            switch (open.tag) {
                .l_angle, .l_brace, .l_bracket, .l_paren => {},
                else => return error.@"Invalid delimiter, expected one of '<', '{', '[', '('",
            }

            const closed = p.next() orelse return error.@"Expected closing delimiter";
            switch (closed.tag) {
                .r_angle, .r_brace, .r_bracket, .r_paren => {},
                else => return error.@"Invalid delimiter, expected one of '>', '}', ']', ')'",
            }

            if (open.tag == .l_angle and closed.tag != .r_angle) {
                return error.@"Expected matching closing angle bracket '>'";
            } else if (open.tag == .l_brace and closed.tag != .r_brace) {
                return error.@"Expected matching closing brace '}'";
            } else if (open.tag == .l_bracket and closed.tag != .r_bracket) {
                return error.@"Expected matching closing bracket ']'";
            } else if (open.tag == .l_paren and closed.tag != .r_paren) {
                return error.@"Expected matching closing paren ')'";
            }

            if (open.len() != closed.len()) {
                return error.@"Expected opening and closing delimiter lengths to match";
            }

            header.delimiter = p.slice(start, p.it.index);
        } else {
            header.delimiter = null;
        }

        if (p.eat(.space, @src())) |space| {
            if (space.len != 1) return error.@"Expected there to be only one space but more were given";
        } else {
            return error.@"Expected a space after delimiter specification";
        }

        var start: usize = undefined;
        const tag = p.eat(.word, @src()) orelse {
            return error.@"Expected 'tag:' or 'file:' following delimiter specification";
        };

        if (mem.eql(u8, tag, "file")) {
            p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'file'";

            if (p.eat(.space, @src())) |space| {
                if (space.len != 1) return error.@"Expected there to be only one space but more were given";
            } else return error.@"Expected a space after 'file:'";

            header.type = .file;
            start = p.it.index;
        } else if (mem.eql(u8, tag, "tag")) {
            p.expect(.colon, @src()) orelse return error.@"Missing ':' after 'tag'";

            if (p.eat(.space, @src())) |space| {
                if (space.len != 1) return error.@"Expected there to be only one space but more were given";
            } else return error.@"Expected a space after 'tag:'";

            p.expect(.hash, @src()) orelse return error.@"Missing '#' after 'tag: '";
            header.type = .tag;
            start = p.it.index;
        } else {
            return error.@"Invalid option given, expected 'tag:' or 'file:'";
        }

        const nl = p.scan(.nl) orelse {
            return error.@"Expected a newline after the header";
        };

        header.resource = p.slice(start, nl.start);
        if (header.resource.len == 0) {
            switch (header.type) {
                .file => return error.@"Missing file name",
                .tag => return error.@"Missing tag name",
            }
        }

        const len = (p.it.index - 1) - header_start;

        if ((p.eat(.space, @src()) orelse "").len != 4) {
            return error.@"Expected the dividing line to be indented by 4 spaces";
        }

        const line = p.eat(.line, @src()) orelse {
            return error.@"Expected a dividing line of '-' of the same length as the header";
        };

        if (line.len != len) {
            log.debug("header {d} line {d}", .{ len, line.len });
            return error.@"Expected the division line to be of the same length as the header";
        }

        if ((p.eat(.nl, @src()) orelse "").len < 2) {
            return error.@"Expected at least one blank line after the division line";
        }

        return header;
    }

    test "parse header line" {
        const common: Header = .{
            .language = "zig",
            .delimiter = "{{}}",
            .resource = "hash",
            .type = .tag,
        };

        try testing.expectError(
            error.@"Expected a space between 'lang:' and the language name",
            testParseHeader("lang:zig", common),
        );

        try testing.expectError(
            error.@"Missing 'esc:' delimiter specification",
            testParseHeader("lang: zig ", common),
        );

        try testing.expectError(
            error.@"Missing ':' after 'esc'",
            testParseHeader("lang: zig esc", common),
        );

        try testing.expectError(
            error.@"Expected a space between 'esc:' and the delimiter specification",
            testParseHeader("lang: zig esc:", common),
        );

        try testing.expectError(
            error.@"Expected closing delimiter",
            testParseHeader("lang: zig esc: {", common),
        );

        try testing.expectError(
            error.@"Expected matching closing angle bracket '>'",
            testParseHeader("lang: zig esc: <}", common),
        );

        try testing.expectError(
            error.@"Expected matching closing brace '}'",
            testParseHeader("lang: zig esc: {>", common),
        );

        try testing.expectError(
            error.@"Expected matching closing bracket ']'",
            testParseHeader("lang: zig esc: [>", common),
        );

        try testing.expectError(
            error.@"Expected matching closing paren ')'",
            testParseHeader("lang: zig esc: (>", common),
        );

        try testing.expectError(
            error.@"Invalid delimiter, expected one of '<', '{', '[', '('",
            testParseHeader("lang: zig esc: foo", common),
        );

        try testing.expectError(
            error.@"Invalid delimiter, expected one of '>', '}', ']', ')'",
            testParseHeader("lang: zig esc: <oo", common),
        );

        try testing.expectError(
            error.@"Expected opening and closing delimiter lengths to match",
            testParseHeader("lang: zig esc: {}}", common),
        );

        try testing.expectError(
            error.@"Expected a space after delimiter specification",
            testParseHeader("lang: zig esc: {{}}", common),
        );

        try testing.expectError(
            error.@"Expected 'tag:' or 'file:' following delimiter specification",
            testParseHeader("lang: zig esc: {{}} ", common),
        );

        try testing.expectError(
            error.@"Invalid option given, expected 'tag:' or 'file:'",
            testParseHeader("lang: zig esc: {{}} none", common),
        );

        try testing.expectError(
            error.@"Missing ':' after 'file'",
            testParseHeader("lang: zig esc: {{}} file", common),
        );

        try testing.expectError(
            error.@"Expected a space after 'file:'",
            testParseHeader("lang: zig esc: {{}} file:", common),
        );

        try testing.expectError(
            error.@"Missing file name",
            testParseHeader("lang: zig esc: {{}} file: \n", common),
        );

        try testing.expectError(
            error.@"Missing ':' after 'tag'",
            testParseHeader("lang: zig esc: {{}} tag", common),
        );

        try testing.expectError(
            error.@"Expected a space after 'tag:'",
            testParseHeader("lang: zig esc: {{}} tag:", common),
        );

        try testing.expectError(
            error.@"Missing '#' after 'tag: '",
            testParseHeader("lang: zig esc: {{}} tag: ", common),
        );

        try testing.expectError(
            error.@"Expected a newline after the header",
            testParseHeader("lang: zig esc: {{}} tag: #", common),
        );

        try testing.expectError(
            error.@"Missing tag name",
            testParseHeader("lang: zig esc: {{}} tag: #\n", common),
        );

        try testing.expectError(
            error.@"Expected the dividing line to be indented by 4 spaces",
            testParseHeader("lang: zig esc: {{}} tag: #hash\n", common),
        );

        try testing.expectError(
            error.@"Expected a dividing line of '-' of the same length as the header",
            testParseHeader("lang: zig esc: {{}} tag: #hash\n    ", common),
        );

        try testing.expectError(
            error.@"Expected the division line to be of the same length as the header",
            testParseHeader("lang: zig esc: {{}} tag: #hash\n    ----------------", common),
        );

        try testing.expectError(
            error.@"Expected at least one blank line after the division line",
            testParseHeader("lang: zig esc: {{}} tag: #hash\n    ------------------------------", common),
        );

        try testing.expectError(
            error.@"Expected at least one blank line after the division line",
            testParseHeader("lang: zig esc: {{}} tag: #hash\n    ------------------------------\n", common),
        );

        try testParseHeader("lang: zig esc: {{}} tag: #hash\n    ------------------------------\n\n", common);
    }

    fn testParseHeader(text: []const u8, expected: Header) !void {
        var p: Parser = .{ .it = .{ .bytes = text }, .obj = .{ .text = text } };
        const header = try p.parseHeaderLine();

        testing.expectEqualStrings(expected.language, header.language) catch return error.@"Language is not the same";

        if (expected.delimiter != null and header.delimiter != null) {
            testing.expectEqualStrings(expected.language, header.language) catch return error.@"Delimiter is not the same";
        } else if (expected.delimiter == null and header.delimiter != null) {
            return error.@"Expected delimiter to be null";
        } else if (expected.delimiter != null and header.delimiter == null) {
            return error.@"Expected delimiter to not be null";
        }

        testing.expectEqualStrings(expected.resource, header.resource) catch return error.@"Resource is not the same";
        testing.expectEqual(expected.type, header.type) catch return error.@"Type is not the same";
    }

### Body
TODO: link tags to their definition

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

    fn parseBody(p: *Parser, gpa: *Allocator, header: Header) !void {
        log.debug("begin parsing body", .{});
        defer log.debug("end parsing body", .{});

        const entry_point = @intCast(u32, p.obj.program.len);

        var nl: usize = 0;
        while (p.eat(.space, @src())) |space| {
            if (space.len < 4) break;
            nl = 0;

            var sol = p.it.index - (space.len - 4);
            while (p.next()) |token| switch (token.tag) {
                .nl => {
                    nl = token.len();

                    try p.emitWrite(gpa, .{
                        .start = @intCast(u32, sol),
                        .len = @intCast(u16, token.start - sol),
                        .nl = @intCast(u16, nl),
                    });
                    break;
                },

                .l_angle,
                .l_brace,
                .l_bracket,
                .l_paren,
                => if (header.delimiter) |delim| {
                    if (delim[0] != @enumToInt(token.tag)) {
                        log.debug("dilimiter doesn't match, skipping", .{});
                        continue;
                    }

                    if (delim.len != token.len() * 2) {
                        log.debug("dilimiter length doesn't match, skipping", .{});
                        continue;
                    }

                    if (token.start - sol < 0) {
                        try p.emitWrite(gpa, .{
                            .start = @intCast(u32, sol),
                            .len = @intCast(u16, token.start - sol),
                            .nl = 0,
                        });
                    }

                    try p.parseDelimiter(gpa, delim, token.start - sol);
                    sol = p.it.index;
                },

                else => {},
            };
        }

        const len = p.obj.program.len;
        if (len != 0) {
            const item = &p.obj.program.items(.data)[len - 1].write;
            item.nl = 0;
            if (item.len == 0) p.obj.program.len -= 1;
        }

        if (nl < 2) {
            return error.@"Expected a blank line after the end of the code block";
        }

        switch (header.type) {
            .tag => {
                const adj = try p.obj.adjacent.getOrPut(gpa, header.resource);
                if (adj.found_existing) {
                    try p.writeJmp(adj.value_ptr.exit, .{
                        .address = entry_point,
                        .module = 0,
                    });
                } else {
                    adj.value_ptr.entry = entry_point;
                }

                adj.value_ptr.exit = @intCast(u32, p.obj.program.len);
            },

            .file => {
                const file = try p.obj.files.getOrPut(gpa, header.resource);
                if (file.found_existing) return error.@"Multiple file outputs with the same name";
                file.value_ptr.* = entry_point;
            },
        }

        try p.emitRet(gpa);
    }

Delimiters

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

    fn parseDelimiter(
        p: *Parser,
        gpa: *Allocator,
        delim: []const u8,
        indent: usize,
    ) !void {
        log.debug("parsing call", .{});

        var pipe = false;
        var colon = false;
        var reached_end = false;

        const tag = blk: {
            const start = p.it.index;
            while (p.next()) |sub| switch (sub.tag) {
                .nl => return error.@"Unexpected newline",
                .pipe => {
                    pipe = true;
                    break :blk p.it.bytes[start..sub.start];
                },
                .colon => {
                    colon = true;
                    break :blk p.it.bytes[start..sub.start];
                },

                .r_angle,
                .r_brace,
                .r_bracket,
                .r_paren,
                => if (@enumToInt(sub.tag) == delim[delim.len - 1]) {
                    if (delim.len != sub.len() * 2) {
                        return error.@"Expected a closing delimiter of equal length";
                    }
                    reached_end = true;
                    break :blk p.it.bytes[start..sub.start];
                },

                else => {},
            };

            return error.@"Unexpected end of file";
        };


Type casts must be given if the imported code block has a different type
than the target code block.

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

        if (colon) {
            const ty = p.eat(.word, @src()) orelse return error.@"Missing 'from' following ':'";
            if (!mem.eql(u8, ty, "from")) return error.@"Unknown type operation";
            p.expect(.l_paren, @src()) orelse return error.@"Expected '(' following 'from'";
            p.expect(.word, @src()) orelse return error.@"Expected type name";
            p.expect(.r_paren, @src()) orelse return error.@"Expected ')' following type name";
        }

Pipes pass code blocks through external programs.

    lang: zig esc: none tag: #zangle parser
    ---------------------------------------

        if (pipe or p.eat(.pipe, @src()) != null) {
            const index = @intCast(u32, p.it.index);
            const shell = p.eat(.word, @src()) orelse {
                return error.@"Missing command following '|'";
            };

            if (shell.len > 255) return error.@"Shell command name too long";
            try p.emitShell(gpa, .{
                .command = index,
                .module = 0xffff,
                .len = @intCast(u8, shell.len),
                .pad = 0,
            });
        }

        try p.emitCall(gpa, tag, .{
            .address = undefined,
            .module = undefined,
            .indent = @intCast(u16, indent),
        });

        if (!reached_end) {
            const last = p.next() orelse return error.@"Expected closing delimiter";

            if (last.len() * 2 != delim.len) {
                return error.@"Expected closing delimiter length to match";
            }

            if (@enumToInt(last.tag) != delim[delim.len - 1]) {
                return error.@"Invalid closing delimiter";
            }
        }
    }

    pub fn parse(gpa: *Allocator, text: []const u8) !Linker.Object {
        var p: Parser = .{
            .it = .{ .bytes = text },
            .obj = .{ .text = text },
        };

        errdefer p.obj.deinit(gpa);

        var code_block = false;
        while (p.next()) |token| {
            if (token.tag == .nl and token.len() >= 2) {
                if (p.eat(.space, @src())) |space| if (space.len == 4 and !code_block) {
                    const header = p.parseHeaderLine() catch |e| switch (e) {
                        error.@"Missing language specification" => {
                            code_block = true;
                            continue;
                        },
                        else => |err| return err,
                    };

                    try p.parseBody(gpa, header);
                } else if (space.len < 4) {
                    code_block = false;
                };
            }
        }

        return p.obj;
    }

    test "parse body" {
        const text =
            \\    <<a b c:from(t)|f>>
            \\    [[a b c | : a}}
            \\    <<b|k>>
            \\    <<b:from(k)>>
            \\    <<<|:>>
            \\    <|:>
            \\
            \\text
        ;

        var p: Parser = .{ .it = .{ .bytes = text }, .obj = .{ .text = text } };
        defer p.obj.deinit(testing.allocator);
        try p.parseBody(testing.allocator, .{
            .language = "",
            .delimiter = "<<>>",
            .resource = "",
            .type = .tag,
        });
    }

    test "compile single tag" {
        const text =
            \\    <<a b c>>
            \\    <<. . .:from(zig)>>
            \\    <<1 2 3|com>>
            \\
            \\end
        ;

        var p: Parser = .{ .it = .{ .bytes = text }, .obj = .{ .text = text } };
        defer p.obj.deinit(testing.allocator);
        try p.parseBody(testing.allocator, .{
            .language = "",
            .delimiter = "<<>>",
            .resource = "foo",
            .type = .tag,
        });

        try testing.expect(p.obj.symbols.contains("a b c"));
        try testing.expect(p.obj.symbols.contains("1 2 3"));
        try testing.expect(p.obj.symbols.contains(". . ."));
    }

    const TestCompileResult = struct {
        program: []const Instruction.Opcode,
        symbols: []const []const u8,
        exports: []const []const u8,
    };

    fn testCompile(
        text: []const u8,
        result: TestCompileResult,
    ) !void {
        var obj = try Parser.parse(testing.allocator, text);
        defer obj.deinit(testing.allocator);

        errdefer for (obj.program.items(.opcode)) |op| {
            log.debug("{s}", .{@tagName(op)});
        };

        try testing.expectEqualSlices(
            Instruction.Opcode,
            result.program,
            obj.program.items(.opcode),
        );

        for (result.symbols) |sym| if (!obj.symbols.contains(sym)) {
            std.log.err("Missing symbol '{s}'", .{sym});
        };
    }

    test "compile block" {
        try testCompile(
            \\begin
            \\
            \\    lang: zig esc: <<>> tag: #here
            \\    ------------------------------
            \\
            \\    <<example>>
            \\
            \\end
        , .{
            .program = &.{ .call, .ret },
            .symbols = &.{"example"},
            .exports = &.{"here"},
        });
    }

    test "compile block with jump threadding" {
        try testCompile(
            \\begin
            \\
            \\    lang: zig esc: <<>> tag: #here
            \\    ------------------------------
            \\
            \\    <<example>>
            \\
            \\then
            \\
            \\    lang: zig esc: none tag: #here
            \\    ------------------------------
            \\
            \\    more
            \\
            \\end
        , .{
            .program = &.{ .call, .jmp, .write, .ret },
            .symbols = &.{"example"},
            .exports = &.{"here"},
        });
    }

    test "compile block multiple call" {
        try testCompile(
            \\begin
            \\
            \\    lang: zig esc: <<>> tag: #here
            \\    ------------------------------
            \\
            \\    <<one>>
            \\    <<two>>
            \\    <<three>>
            \\
            \\end
        , .{
            .program = &.{ .call, .write, .call, .write, .call, .ret },
            .symbols = &.{ "one", "two", "three" },
            .exports = &.{"here"},
        });
    }

    test "compile block inline" {
        try testCompile(
            \\begin
            \\
            \\    lang: zig esc: <<>> tag: #here
            \\    ------------------------------
            \\
            \\    <<one>><<two>>
            \\
            \\end
        , .{
            .program = &.{ .call, .call, .ret },
            .symbols = &.{ "one", "two" },
            .exports = &.{"here"},
        });
    }

# K

    lang: zig esc: [[]] file: src/main.zig
    --------------------------------------

    const std = @import("std");
    const mem = std.mem;
    const assert = std.debug.assert;
    const testing = std.testing;
    const meta = std.meta;
    const fs = std.fs;
    const io = std.io;
    const os = std.os;

    const Allocator = std.mem.Allocator;
    const ArrayList = std.ArrayListUnmanaged;
    const HashMap = std.AutoArrayHashMapUnmanaged;
    const StringMap = std.StringArrayHashMapUnmanaged;
    const MultiArrayList = std.MultiArrayList;

    test { testing.refAllDecls(@This()); }

    const Tokenizer = struct {
        [[zangle tokenizer]]
    };

    const Parser = struct {
        [[zangle parser]]
        [[zangle parser primitives]]
    };

    const Linker = struct {
        [[linker]]
    };

    const Instruction = struct {
        [[bytecode]]
    };

    const Interpreter = struct {
        [[interpreter step]]
    };

    [[main]]

\begin{comment}

    lang: zig esc: none tag: #zangle tokenizer tests
    ------------------------------------------------

    fn testTokenize(text: []const u8, expected: []const Token.Tag) !void {
        var it: Tokenizer = .{ .bytes = text };

        for (expected) |tag| {
            const token = it.next();
            try testing.expectEqual(tag, token.tag);
        }

        const token = it.next();
        try testing.expectEqual(Token.Tag.eof, token.tag);
        try testing.expectEqual(text.len, token.end);
    }

# Appendix. Parser primitives

    lang: zig esc: [[]] tag: #zangle parser primitives
    --------------------------------------------------

    [[parser codegen]]

    const Loc = std.builtin.SourceLocation;

    pub fn eat(p: *Parser, tag: Token.Tag, loc: Loc) ?[]const u8 {
        const state = p.it;
        const token = p.it.next();
        if (token.tag == tag) {
            return token.slice(p.it.bytes);
        } else {
            log.debug("I'm starving for a '{s}' but this is a '{s}' ({s} {d}:{d})", .{
                @tagName(tag),
                @tagName(token.tag),
                loc.fn_name,
                loc.line,
                loc.column,
            });
            p.it = state;
            return null;
        }
    }

    pub fn next(p: *Parser) ?Token {
        const token = p.it.next();
        if (token.tag != .eof) {
            return token;
        } else {
            return null;
        }
    }

    pub fn scan(p: *Parser, tag: Token.Tag) ?Token {
        while (p.next()) |token| if (token.tag == tag) {
            return token;
        };

        return null;
    }

    pub fn expect(p: *Parser, tag: Token.Tag, loc: Loc) ?void {
        _ = p.eat(tag, loc) orelse {
            log.debug("Wanted a {s}, but got nothing captain ({s} {d}:{d})", .{
                @tagName(tag),
                loc.fn_name,
                loc.line,
                loc.column,
            });
            return null;
        };
    }

    pub fn slice(p: *Parser, from: usize, to: usize) []const u8 {
        assert(from <= to);
        return p.it.bytes[from..to];
    }

    pub fn match(p: *Parser, tag: Token.Tag, text: []const u8) ?void {
        const state = p.it;
        const token = p.it.next();
        if (token.tag == tag and mem.eql(u8, token.slice(p.it.bytes), text)) {
            return;
        } else {
            p.it = state;
            return null;
        }
    }

\end{comment}
