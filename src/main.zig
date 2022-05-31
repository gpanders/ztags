const std = @import("std");

const MyStruct = struct {
    foo: []const u8,
};

var global_var: u32 = 42;

fn sayHello() void {
    std.debug.print("Hello world!\n", .{});
}

pub fn main() anyerror!void {
    sayHello();
}
