const std = @import("std");

const Tags = @This();

const EntryList = std.ArrayListUnmanaged(Entry);

const Kind = enum {
    function,
    field,
    @"struct",
    variable,
};

const Entry = struct {
    ident: []const u8,
    filename: []const u8,
    loc: struct {
        line: usize,
        column: usize,
    },
    kind: Kind,
};

allocator: std.mem.Allocator,
entries: EntryList,
visited: std.StringHashMap(void),

pub fn init(allocator: std.mem.Allocator) Tags {
    return Tags{
        .allocator = allocator,
        .entries = .{},
        .visited = std.StringHashMap(void).init(allocator),
    };
}

pub fn findTags(self: *Tags, fname: []const u8) anyerror!void {
    const gop = try self.visited.getOrPut(fname);
    if (gop.found_existing) {
        return;
    }
    gop.value_ptr.* = {};

    const source = a: {
        var file = try std.fs.cwd().openFile(fname, .{});
        defer file.close();

        const size = try file.getEndPos();
        if (size == 0) {
            return;
        }
        break :a try std.os.mmap(null, size, std.os.PROT.READ, std.os.MAP.SHARED, file.handle, 0);
    };
    defer std.os.munmap(source);

    var ast = try std.zig.parse(self.allocator, std.meta.assumeSentinel(source, 0));
    const tags = ast.nodes.items(.tag);
    const tokens = ast.nodes.items(.main_token);
    const data = ast.nodes.items(.data);
    for (tags) |node, i| {
        switch (node) {
            .builtin_call_two => {
                const main_token = tokens[i];
                const token = ast.tokenSlice(main_token);
                if (std.mem.eql(u8, token[1..], "import")) {
                    const name_index = tokens[data[i].lhs];
                    const name = std.mem.trim(u8, ast.tokenSlice(name_index), "\"");
                    if (std.mem.endsWith(u8, name, ".zig")) {
                        const dir = std.fs.path.dirname(fname) orelse continue;
                        const import_fname = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
                            dir,
                            name,
                        });
                        const resolved = try std.fs.path.resolve(self.allocator, &.{
                            import_fname,
                        });
                        self.findTags(resolved) catch |err| switch (err) {
                            error.FileNotFound => continue,
                            else => return err,
                        };
                    }
                }
            },
            .fn_decl => {
                const name_token = tokens[i] + 1;
                const name = ast.tokenSlice(name_token);
                const offset = ast.tokens.items(.start)[name_token];
                const loc = std.zig.findLineColumn(source, offset);
                try self.entries.append(self.allocator, .{
                    .ident = try self.allocator.dupe(u8, name),
                    .filename = fname,
                    .kind = .function,
                    .loc = .{
                        .line = loc.line,
                        .column = loc.column,
                    },
                });
            },
            .global_var_decl,
            .simple_var_decl,
            .local_var_decl,
            .aligned_var_decl,
            => {
                const name_token = tokens[i] + 1;
                var name = ast.tokenSlice(name_token);
                if (std.mem.eql(u8, name, "_")) {
                    continue;
                }
                if (std.mem.startsWith(u8, name, "@\"")) {
                    name = std.mem.trim(u8, name[1..], "\"");
                }
                const kind = switch (data[i].rhs) {
                    0 => Kind.variable,
                    else => |rhs| switch (tags[rhs]) {
                        .container_decl,
                        .container_decl_trailing,
                        .container_decl_two,
                        .container_decl_two_trailing,
                        .container_decl_arg,
                        .container_decl_arg_trailing,
                        => Kind.@"struct",
                        else => Kind.variable,
                    },
                };
                const offset = ast.tokens.items(.start)[name_token];
                const loc = std.zig.findLineColumn(source, offset);
                try self.entries.append(self.allocator, .{
                    .ident = try self.allocator.dupe(u8, name),
                    .filename = fname,
                    .kind = kind,
                    .loc = .{
                        .line = loc.line,
                        .column = loc.column,
                    },
                });
            },
            .container_field_init,
            .container_field_align,
            .container_field,
            => {
                const name_token = tokens[i];
                var name = ast.tokenSlice(name_token);
                if (std.mem.eql(u8, name, "_")) {
                    continue;
                }
                if (std.mem.startsWith(u8, name, "@\"")) {
                    name = std.mem.trim(u8, name[1..], "\"");
                }
                const offset = ast.tokens.items(.start)[name_token];
                const loc = std.zig.findLineColumn(source, offset);
                try self.entries.append(self.allocator, .{
                    .ident = try self.allocator.dupe(u8, name),
                    .filename = fname,
                    .kind = .field,
                    .loc = .{
                        .line = loc.line,
                        .column = loc.column,
                    },
                });
            },
            else => continue,
        }
    }
}

pub fn write(self: *Tags, output: []const u8) !void {
    var contents = std.ArrayList(u8).init(self.allocator);
    var writer = contents.writer();

    try writer.writeAll(
        \\!_TAG_FILE_SORTED	1	/1 = sorted/
        \\!_TAG_FILE_ENCODING	utf-8	
        \\
    );

    std.sort.sort(Entry, self.entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.ident, b.ident);
        }
    }.lessThan);

    for (self.entries.items) |entry| {
        try writer.print("{s}\t{s}\tcall cursor({d}, {d})|;\"\t{s}\n", .{
            entry.ident,
            entry.filename,
            entry.loc.line + 1,
            entry.loc.column + 1,
            @tagName(entry.kind),
        });
    }

    var file = try std.fs.cwd().createFile(output, .{});
    defer file.close();

    try file.writeAll(contents.items);
}
