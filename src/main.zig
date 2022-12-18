const std = @import("std");

const Options = @import("Options.zig");
const Tags = @import("Tags.zig");

fn usage() void {
    std.debug.print("Usage: {s} [-o OUTPUT] FILES...\n", .{std.os.argv[0]});
}

pub fn main() anyerror!u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var allocator = arena.allocator();

    var options = a: {
        var rc: u8 = 0;
        break :a Options.parse(allocator, &rc) catch |err| switch (err) {
            error.InvalidOption,
            error.MissingArguments,
            => {
                usage();
                return rc;
            },
            else => return err,
        };
    };

    var tags = Tags.init(&arena);

    for (options.arguments) |fname| {
        const full_fname = if (std.fs.path.isAbsolute(fname))
            fname
        else
            try std.fs.cwd().realpathAlloc(allocator, fname);
        tags.findTags(full_fname) catch |err| switch (err) {
            error.NotFile => {
                try std.io.getStdErr().writer().print(
                    "Error: {s} is a directory. Arguments must be Zig source files.\n",
                    .{full_fname},
                );
                return 22; // EINVAL
            },
            else => return err,
        };
    }

    try tags.write(options.output);

    return 0;
}
