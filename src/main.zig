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
            error.InvalidOption, error.MissingArgument => return rc,
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
        defer allocator.free(full_fname);

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
        const content = try tags.write(allocator, options.relative);
        defer allocator.free(content);
        try std.io.getStdOut().writeAll(content);
    } else {
        if (options.append) {
            if (std.fs.cwd().readFileAlloc(allocator, options.output, std.math.maxInt(u32))) |contents| {
                defer allocator.free(contents);
                try tags.read(contents);
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }

        const content = try tags.write(allocator, options.relative);
        defer allocator.free(content);

        try std.fs.cwd().writeFile(options.output, content);
    }

    return 0;
}

test {
    std.testing.refAllDecls(@This());
}
