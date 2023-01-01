const builtin = @import("builtin");
const std = @import("std");

const Options = @import("Options.zig");
const Tags = @import("Tags.zig");

fn usage() void {
    std.debug.print("Usage: {s} [-o OUTPUT] [-r] FILES...\n", .{std.os.argv[0]});
}

pub fn main() anyerror!u8 {
    var base_allocator = switch (builtin.mode) {
        .Debug => std.heap.GeneralPurposeAllocator(.{}){},
        else => std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    defer _ = base_allocator.deinit();

    var allocator = base_allocator.allocator();

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
    defer options.deinit(allocator);

    var tags = Tags.init(allocator, options.relative);
    defer tags.deinit();

    for (options.arguments) |fname| {
        const full_fname = if (std.fs.path.isAbsolute(fname))
            fname
        else
            try std.fs.cwd().realpathAlloc(allocator, fname);
        defer if (fname.ptr != full_fname.ptr) allocator.free(full_fname);

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

test {
    std.testing.refAllDecls(@This());
}
