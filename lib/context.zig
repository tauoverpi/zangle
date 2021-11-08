const lib = @import("lib.zig");

const Interpreter = lib.Interpreter;

pub fn StreamContext(comptime Writer: type) type {
    return struct {
        stream: Writer,

        const Self = @This();

        pub const Error = Writer.Error;

        pub fn init(writer: Writer) Self {
            return .{ .stream = writer };
        }

        pub fn write(self: *Self, vm: *Interpreter, text: []const u8, nl: u16) !void {
            _ = vm;
            try self.stream.writeAll(text);
            try self.stream.writeByteNTimes('\n', nl);
        }

        pub fn indent(self: *Self, vm: *Interpreter) !void {
            try self.stream.writeByteNTimes(' ', vm.indent);
        }
    };
}
