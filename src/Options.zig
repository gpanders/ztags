const std = @import("std");
const config = @import("config");

const Options = @This();

output: []const u8 = "",
relative: bool = false,
append: bool = false,
arguments: []const []const u8 = undefined,

const Option = enum(u8) {
    output = 'o',
    relative = 'r',
    append = 'a',
    version = 'V',
    help = 'h',

    fn from(c: u8) ?Option {
        inline for (@typeInfo(Option).Enum.fields) |field| {
            if (field.value == c) {
                return @enumFromInt(c);
            }
        }

        return null;
    }
};

fn usage() void {
    std.io.getStdErr().writer().writeAll("Usage: " ++ config.name ++ " [-o OUTPUT] [-a] [-r] FILES...\n") catch {};
}

pub fn parse(allocator: std.mem.Allocator) !Options {
    var it = try std.process.argsWithAllocator(allocator);
    defer it.deinit();

    _ = it.skip();

    var errmsg: ?[]const u8 = null;
    return parseIter(allocator, &it, &errmsg) catch |err| {
        if (errmsg) |e| {
            std.io.getStdErr().writer().print("{s}: {s}\n", .{ config.name, e }) catch {};
            allocator.free(e);
        }

        switch (err) {
            error.ShowHelp, error.InvalidOption, error.MissingArgument => usage(),
            error.ShowVersion => {
                std.io.getStdErr().writeAll(config.name ++ " " ++ config.version ++ "\n") catch {};
            },
            else => {},
        }

        return err;
    };
}

fn parseIter(allocator: std.mem.Allocator, iter: anytype, errmsg: *?[]const u8) !Options {
    var arguments = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (arguments.items) |arg| allocator.free(arg);
        arguments.deinit();
    }

    var options = Options{};
    errdefer if (options.output.len > 0) allocator.free(options.output);

    var next_option: ?Option = null;
    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            for (arg[1..]) |c| {
                if (next_option) |opt| {
                    errmsg.* = try std.fmt.allocPrint(
                        allocator,
                        "Option '{c}' missing required argument.",
                        .{@intFromEnum(opt)},
                    );
                    return error.MissingArgument;
                }

                if (Option.from(c)) |opt| {
                    switch (opt) {
                        .output => next_option = opt,
                        .relative => options.relative = true,
                        .append => options.append = true,
                        .help => return error.ShowHelp,
                        .version => return error.ShowVersion,
                    }
                } else {
                    errmsg.* = try std.fmt.allocPrint(allocator, "Unexpected option: '{c}'.", .{c});
                    return error.InvalidOption;
                }
            }
        } else if (next_option) |opt| {
            switch (opt) {
                .output => options.output = try allocator.dupe(u8, arg),
                // Unreachable: next_option is only ever set with the enum
                // values above
                else => unreachable,
            }
            next_option = null;
        } else {
            const a = try allocator.dupe(u8, arg);
            errdefer allocator.free(a);
            try arguments.append(a);
        }
    }

    if (next_option) |opt| {
        errmsg.* = try std.fmt.allocPrint(
            allocator,
            "Option '{c}' missing required argument.",
            .{@intFromEnum(opt)},
        );
        return error.MissingArgument;
    }

    if (options.output.len == 0) {
        options.output = try allocator.dupe(u8, "tags");
    }

    if (arguments.items.len == 0) {
        errmsg.* = try allocator.dupe(u8, "No files specified.");
        return error.MissingArgument;
    }

    options.arguments = try arguments.toOwnedSlice();
    return options;
}

pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
    if (self.output.len > 0) allocator.free(self.output);
    for (self.arguments) |arg| allocator.free(arg);
    allocator.free(self.arguments);
    self.* = undefined;
}

const TestIterator = struct {
    args: []const []const u8,
    index: usize,

    const Self = @This();

    fn init(args: []const []const u8) Self {
        return Self{
            .args = args,
            .index = 0,
        };
    }

    fn next(self: *Self) ?[]const u8 {
        if (self.index < self.args.len) {
            defer self.index += 1;
            return self.args[self.index];
        }

        return null;
    }
};

test "parseIter" {
    var errmsg: ?[]const u8 = null;

    {
        defer if (errmsg) |e| {
            std.testing.allocator.free(e);
            errmsg = null;
        };

        // Default output value
        var it = TestIterator.init(&.{
            "hello.zig", "world.zig",
        });

        var options = try Options.parseIter(std.testing.allocator, &it, &errmsg);
        defer options.deinit(std.testing.allocator);

        try std.testing.expect(errmsg == null);
        try std.testing.expectEqualStrings("tags", options.output);
        try std.testing.expectEqual(false, options.relative);
        try std.testing.expectEqual(false, options.append);
        try std.testing.expectEqual(@as(usize, 2), options.arguments.len);
        try std.testing.expectEqualStrings("hello.zig", options.arguments[0]);
        try std.testing.expectEqualStrings("world.zig", options.arguments[1]);
    }

    {
        defer if (errmsg) |e| {
            std.testing.allocator.free(e);
            errmsg = null;
        };

        // Supplied output value
        var it = TestIterator.init(&.{
            "-o", "foo", "-r", "hello.zig",
        });

        var options = try Options.parseIter(std.testing.allocator, &it, &errmsg);
        defer options.deinit(std.testing.allocator);

        try std.testing.expect(errmsg == null);
        try std.testing.expectEqualStrings("foo", options.output);
        try std.testing.expectEqual(true, options.relative);
        try std.testing.expectEqual(false, options.append);
    }

    {
        defer if (errmsg) |e| {
            std.testing.allocator.free(e);
            errmsg = null;
        };

        // Can output to stdout
        var it = TestIterator.init(&.{
            "-o", "-", "hello.zig",
        });

        var options = try Options.parseIter(std.testing.allocator, &it, &errmsg);
        defer options.deinit(std.testing.allocator);

        try std.testing.expect(errmsg == null);
        try std.testing.expectEqualStrings("-", options.output);
    }

    {
        defer if (errmsg) |e| {
            std.testing.allocator.free(e);
            errmsg = null;
        };

        // error: Missing arguments
        var it = TestIterator.init(&.{
            "-o", "foo",
        });

        const options = Options.parseIter(std.testing.allocator, &it, &errmsg);
        try std.testing.expect(errmsg != null);
        try std.testing.expectError(error.MissingArgument, options);
        try std.testing.expectEqualStrings("No files specified.", errmsg.?);
    }

    {
        defer if (errmsg) |e| {
            std.testing.allocator.free(e);
            errmsg = null;
        };

        // error: Missing option value
        var it = TestIterator.init(&.{
            "hello.zig", "-o",
        });

        const options = Options.parseIter(std.testing.allocator, &it, &errmsg);
        try std.testing.expectError(error.MissingArgument, options);
        try std.testing.expect(errmsg != null);
        try std.testing.expectEqualStrings("Option 'o' missing required argument.", errmsg.?);
    }

    {
        defer if (errmsg) |e| {
            std.testing.allocator.free(e);
            errmsg = null;
        };

        // error: Missing option value
        var it = TestIterator.init(&.{
            "-o", "-a", "hello.zig",
        });

        const options = Options.parseIter(std.testing.allocator, &it, &errmsg);
        try std.testing.expectError(error.MissingArgument, options);
        try std.testing.expect(errmsg != null);
        try std.testing.expectEqualStrings("Option 'o' missing required argument.", errmsg.?);
    }

    {
        defer if (errmsg) |e| {
            std.testing.allocator.free(e);
            errmsg = null;
        };

        // Multiple options
        var it = TestIterator.init(&.{
            "-rao", "tags", "hello.zig",
        });

        var options = try Options.parseIter(std.testing.allocator, &it, &errmsg);
        defer options.deinit(std.testing.allocator);

        try std.testing.expect(errmsg == null);
        try std.testing.expectEqual(true, options.relative);
        try std.testing.expectEqual(true, options.append);
    }

    {
        defer if (errmsg) |e| {
            std.testing.allocator.free(e);
            errmsg = null;
        };

        // error: Option after option that expects argument
        var it = TestIterator.init(&.{
            "-roa", "tags", "hello.zig",
        });

        const options = Options.parseIter(std.testing.allocator, &it, &errmsg);
        try std.testing.expectError(error.MissingArgument, options);
        try std.testing.expect(errmsg != null);
        try std.testing.expectEqualStrings("Option 'o' missing required argument.", errmsg.?);
    }
}
