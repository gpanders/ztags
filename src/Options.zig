const std = @import("std");

const Options = @This();

output: []const u8,
arguments: []const []const u8 = undefined,

const OptionField = std.meta.FieldEnum(Options);

const options_map = std.ComptimeStringMap(OptionField, .{
    .{ "o", .output },
});

fn defaults() Options {
    return .{
        .output = "tags",
    };
}

pub fn parse(allocator: std.mem.Allocator, rc: *u8) !Options {
    var args = std.process.args();
    _ = args.skip();
    var arguments = std.ArrayList([]const u8).init(allocator);
    var options = Options.defaults();
    var next_option: ?OptionField = null;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (arg.len < 2) {
                rc.* = 1;
                return error.InvalidOption;
            } else if (options_map.get(arg[1..])) |opt| {
                next_option = opt;
            } else {
                rc.* = if (std.mem.eql(u8, arg[1..], "h")) 0 else 1;
                return error.InvalidOption;
            }
        } else if (next_option) |opt| {
            switch (opt) {
                .output => options.output = arg,
                else => unreachable,
            }
            next_option = null;
        } else {
            try arguments.append(arg);
        }
    }

    if (arguments.items.len == 0) {
        rc.* = 1;
        return error.MissingArguments;
    }

    options.arguments = arguments.toOwnedSlice();
    return options;
}
