const builtin = @import("builtin");
const std = @import("std");

const Options = @import("Options.zig");
const Tags = @import("Tags.zig");

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
            error.InvalidOption, error.MissingArguments => return rc,
            else => return err,
        };
    };
    defer options.deinit(allocator);

    var tags = Tags.init(allocator);
    defer tags.deinit();

    for (options.arguments) |fname| {
        const full_fname = if (std.fs.path.isAbsolute(fname))
            try allocator.dupe(u8, fname)
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

    if (std.mem.eql(u8, options.output, "-")) {
        const content = try tags.write(options.relative);
        defer allocator.free(content);
        try std.io.getStdOut().writeAll(content);
    } else {
        var file = try std.fs.cwd().createFile(options.output, .{ .read = true, .truncate = false });
        defer file.close();

        if (options.append) {
            const contents = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
            defer allocator.free(contents);

            try tags.read(contents);
        }

        const content = try tags.write(options.relative);
        defer allocator.free(content);

        try std.fs.cwd().writeFile(options.output, content);
    }

    return 0;
}

test {
    std.testing.refAllDecls(@This());
}
