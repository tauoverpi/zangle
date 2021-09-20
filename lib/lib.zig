pub const Tokenizer = @import("Tokenizer.zig");
pub const Parser = @import("Parser.zig");
pub const Linker = @import("Linker.zig");
pub const Instruction = @import("Instruction.zig");
pub const Interpreter = @import("Interpreter.zig");

test {
    _ = Tokenizer;
    _ = Parser;
    _ = Linker;
    _ = Instruction;
    _ = Interpreter;
}
