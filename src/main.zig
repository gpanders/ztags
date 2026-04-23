const builtin = @import("builtin");
const std = @import("std");
const config = @import("config");

const Options = @import("Options.zig");
const Tags = @import("Tags.zig");

pub fn main(init: std.process.Init) anyerror!u8 {
    const io = init.io;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    defer stderr_writer.flush() catch {};

    const stderr = &stderr_writer.interface;

    const allocator = switch (builtin.mode) {
        .Debug => init.gpa,
        else => init.arena.allocator(),
    };

    var options = a: {
        break :a Options.parse(stderr, allocator, init.minimal.args) catch |err| switch (err) {
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
        const full_fname: []const u8 = if (std.fs.path.isAbsolute(fname))
            try allocator.dupe(u8, fname)
        else
            std.Io.Dir.cwd().realPathFileAlloc(io, fname, allocator) catch |err| switch (err) {
                error.FileNotFound => {
                    stderr.print(
                        "{s}: Cannot open {s}: File not found.\n",
                        .{ config.name, fname },
                    ) catch {};
                    return 22; // EINVAL
                },
                else => return err,
            };
        defer allocator.free(full_fname);

        tags.findTags(io, full_fname) catch |err| switch (err) {
            error.IsDir => {
                stderr.print(
                    "{s}: {s} is a directory. Arguments must be Zig source files.\n",
                    .{ config.name, full_fname },
                ) catch {};
                return 22; // EINVAL
            },
            else => return err,
        };
    }

    if (std.mem.eql(u8, options.output, "-")) {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        try tags.write(io, stdout, options.relative);
        try stdout.flush();
    } else {
        if (options.append) {
            if (std.Io.Dir.cwd().readFileAlloc(io, options.output, allocator, .limited(std.math.maxInt(usize)))) |contents| {
                defer allocator.free(contents);
                try tags.read(contents);
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }

        var contents = std.Io.Writer.Allocating.init(allocator);
        defer contents.deinit();

        try tags.write(io, &contents.writer, options.relative);

        const data = try contents.toOwnedSlice();
        defer allocator.free(data);

        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = options.output,
            .data = data,
        });
    }

    return 0;
}

test {
    std.testing.refAllDecls(@This());
}
