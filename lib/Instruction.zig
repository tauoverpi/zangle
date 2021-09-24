const std = @import("std");
const assert = std.debug.assert;

const Instruction = @This();

opcode: Opcode,
data: Data,

pub const List = std.MultiArrayList(Instruction);
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

    pub const Ret = extern struct {
        start: u32,
        len: u16,
        pad: u16 = 0,
    };
    pub const Jmp = extern struct {
        address: u32,
        module: u16,
        generation: u16 = 0,
    };
    pub const Call = extern struct {
        address: u32,
        module: u16,
        indent: u16,
    };
    pub const Shell = extern struct {
        command: u32,
        module: u16,
        len: u8,
        pad: u8,
    };
    pub const Write = extern struct {
        start: u32,
        len: u16,
        nl: u16,
    };
};

comptime {
    assert(@sizeOf(Data) == 8);
}
