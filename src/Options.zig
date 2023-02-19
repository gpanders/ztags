const std = @import("std");

const Options = @This();

output: []const u8 = "",
relative: bool = false,
append: bool = false,
arguments: []const []const u8 = undefined,

const OptionField = std.meta.FieldEnum(Options);

fn getOption(opt: u8) ?OptionField {
    return switch (opt) {
        'a' => .append,
        'o' => .output,
        'r' => .relative,
        else => null,
    };
}

fn usage(exe: []const u8) void {
    std.debug.print("Usage: {s} [-o OUTPUT] [-a] [-r] FILES...\n", .{exe});
}

pub fn parse(allocator: std.mem.Allocator, rc: *u8) !Options {
    var it = try std.process.argsWithAllocator(allocator);
    defer it.deinit();

    const exe = it.next();

    return parseIter(allocator, &it, rc) catch |err| {
        switch (err) {
            error.InvalidOption, error.MissingArgument => usage(exe orelse "ztags"),
            else => {},
        }

        return err;
    };
}

fn parseIter(allocator: std.mem.Allocator, iter: anytype, rc: *u8) !Options {
    var arguments = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (arguments.items) |arg| allocator.free(arg);
        arguments.deinit();
    }

    var options = Options{};
    errdefer if (options.output.len > 0) allocator.free(options.output);

    var next_option: ?OptionField = null;
    while (iter.next()) |arg| {
        if (next_option) |opt| {
            switch (opt) {
                .output => options.output = try allocator.dupe(u8, arg),
                else => unreachable,
            }
            next_option = null;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            if (arg.len < 2) {
                rc.* = 1;
                return error.InvalidOption;
            } else for (arg[1..]) |c| {
                if (next_option != null) {
                    rc.* = 1;
                    return error.MissingArgument;
                }

                if (getOption(c)) |opt| {
                    switch (opt) {
                        .output => next_option = opt,
                        .relative => options.relative = true,
                        .append => options.append = true,
                        else => unreachable,
                    }
                } else {
                    rc.* = if (c == 'h') 0 else 1;
                    return error.InvalidOption;
                }
            }
        } else {
            const a = try allocator.dupe(u8, arg);
            errdefer allocator.free(a);
            try arguments.append(a);
        }
    }

    if (next_option) |_| {
        rc.* = 1;
        return error.MissingArgument;
    }

    if (options.output.len == 0) {
        options.output = try allocator.dupe(u8, "tags");
    }

    if (arguments.items.len == 0) {
        rc.* = 1;
        return error.MissingArgument;
    }

    rc.* = 0;

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
    var rc: u8 = 0;

    {
        // Default output value
        var it = TestIterator.init(&.{
            "hello.zig", "world.zig",
        });

        var options = try Options.parseIter(std.testing.allocator, &it, &rc);
        defer options.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u8, 0), rc);
        try std.testing.expectEqualStrings("tags", options.output);
        try std.testing.expectEqual(false, options.relative);
        try std.testing.expectEqual(false, options.append);
        try std.testing.expectEqual(@as(usize, 2), options.arguments.len);
        try std.testing.expectEqualStrings("hello.zig", options.arguments[0]);
        try std.testing.expectEqualStrings("world.zig", options.arguments[1]);
    }

    {
        // Supplied output value
        var it = TestIterator.init(&.{
            "-o", "foo", "-r", "hello.zig",
        });

        var options = try Options.parseIter(std.testing.allocator, &it, &rc);
        defer options.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u8, 0), rc);
        try std.testing.expectEqualStrings("foo", options.output);
        try std.testing.expectEqual(true, options.relative);
        try std.testing.expectEqual(false, options.append);
    }

    {
        // error: Missing arguments
        var it = TestIterator.init(&.{
            "-o", "foo",
        });

        var options = Options.parseIter(std.testing.allocator, &it, &rc);
        try std.testing.expectEqual(@as(u8, 1), rc);
        try std.testing.expectError(error.MissingArgument, options);
    }

    {
        // error: Missing option value
        var it = TestIterator.init(&.{
            "hello.zig", "-o",
        });

        var options = Options.parseIter(std.testing.allocator, &it, &rc);
        try std.testing.expectEqual(@as(u8, 1), rc);
        try std.testing.expectError(error.MissingArgument, options);
    }

    {
        // Multiple options
        var it = TestIterator.init(&.{
            "-rao", "tags", "hello.zig",
        });

        var options = try Options.parseIter(std.testing.allocator, &it, &rc);
        defer options.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u8, 0), rc);
        try std.testing.expectEqual(true, options.relative);
        try std.testing.expectEqual(true, options.append);
    }

    {
        // error: Option after option that expects argument
        var it = TestIterator.init(&.{
            "-roa", "tags", "hello.zig",
        });

        var options = Options.parseIter(std.testing.allocator, &it, &rc);
        try std.testing.expectEqual(@as(u8, 1), rc);
        try std.testing.expectError(error.MissingArgument, options);
    }
}
