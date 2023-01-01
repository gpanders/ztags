const b = @import("b.zig");

const MyEnum = enum {
    a,
    b,
};

const MyStruct = struct {
    c: u8,
    d: u8,
};

const MyUnion = union(enum) {
    e: void,
    f: u32,
};

fn myFunction(s: MyStruct, e: MyEnum, u: MyUnion) u8 {
    const x = switch (e) {
        .a => s.d,
        .b => s.c,
    };

    const y = switch (u) {
        .e => null,
        .f => |f| f,
    };

    if (x > y) {
        return x;
    }

    return b.anotherFunction(y);
}
