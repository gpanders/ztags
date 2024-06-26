const builtin = @import("builtin");
const std = @import("std");
const config = @import("config");

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
        break :a Options.parse(allocator) catch |err| switch (err) {
            // Showing help or version information should not return an error
            // code
            error.ShowHelp, error.ShowVersion => return 0,

            // These are errors from our own arg parsing. These will print a
            // user-friendly error message and set an error exit code
            error.InvalidOption, error.MissingArgument => return 1,

            // These are unexpected errors. In this case print the full error
            // return trace
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
            std.fs.cwd().realpathAlloc(allocator, fname) catch |err| switch (err) {
                error.FileNotFound => {
                    std.io.getStdErr().writer().print(
                        "{s}: Cannot open {s}: File not found.\n",
                        .{ config.name, fname },
                    ) catch {};
                    return 22; // EINVAL
                },
                else => return err,
            };
        defer allocator.free(full_fname);

        tags.findTags(full_fname) catch |err| switch (err) {
            error.IsDir => {
                std.io.getStdErr().writer().print(
                    "{s}: {s} is a directory. Arguments must be Zig source files.\n",
                    .{ config.name, full_fname },
                ) catch {};
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

        try std.fs.cwd().writeFile(.{
            .sub_path = options.output,
            .data = content,
        });
    }

    return 0;
}

test {
    std.testing.refAllDecls(@This());
}
