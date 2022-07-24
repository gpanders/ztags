const std = @import("std");

const Tags = @This();

const EntryList = std.ArrayListUnmanaged(Entry);

const Kind = enum {
    function,
    field,
    @"struct",
    @"enum",
    @"union",
    variable,
    constant,
};

const Entry = struct {
    ident: []const u8,
    filename: []const u8,
    text: []const u8,
    kind: Kind,
};

arena: *std.heap.ArenaAllocator,
entries: EntryList,
visited: std.StringHashMap(void),

pub fn init(arena: *std.heap.ArenaAllocator) Tags {
    return Tags{
        .arena = arena,
        .entries = .{},
        .visited = std.StringHashMap(void).init(arena.allocator()),
    };
}

pub fn findTags(self: *Tags, fname: []const u8) anyerror!void {
    const gop = try self.visited.getOrPut(fname);
    if (gop.found_existing) {
        return;
    }
    gop.value_ptr.* = {};

    const mapped = a: {
        var file = try std.fs.cwd().openFile(fname, .{});
        defer file.close();

        const size = try file.getEndPos();
        if (size == 0) {
            return;
        }
        break :a try std.os.mmap(null, size, std.os.PROT.READ, std.os.MAP.SHARED, file.handle, 0);
    };
    defer std.os.munmap(mapped);

    const source = std.meta.assumeSentinel(mapped, 0);

    var allocator = self.arena.allocator();
    var ast = try std.zig.parse(allocator, source);
    const tags = ast.nodes.items(.tag);
    const tokens = ast.nodes.items(.main_token);
    const data = ast.nodes.items(.data);
    for (tags) |node, i| {
        var ident: ?[]const u8 = null;
        var kind: ?Kind = null;

        switch (node) {
            .builtin_call_two => {
                const builtin = ast.tokenSlice(tokens[i]);
                if (std.mem.eql(u8, builtin[1..], "import")) {
                    const name_index = tokens[data[i].lhs];
                    const name = std.mem.trim(u8, ast.tokenSlice(name_index), "\"");
                    if (std.mem.endsWith(u8, name, ".zig")) {
                        const dir = std.fs.path.dirname(fname) orelse continue;
                        const import_fname = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
                            dir,
                            name,
                        });
                        const resolved = try std.fs.path.resolve(allocator, &.{import_fname});
                        self.findTags(resolved) catch |err| switch (err) {
                            error.FileNotFound => continue,
                            else => return err,
                        };
                    }
                }
                continue;
            },
            .fn_decl => {
                ident = ast.tokenSlice(tokens[i] + 1);
                kind = .function;
            },
            .global_var_decl,
            .simple_var_decl,
            .local_var_decl,
            .aligned_var_decl,
            => {
                var name = ast.tokenSlice(tokens[i] + 1);
                if (std.mem.eql(u8, name, "_")) {
                    continue;
                }
                if (std.mem.startsWith(u8, name, "@\"")) {
                    name = std.mem.trim(u8, name[1..], "\"");
                }

                ident = name;
                kind = if (std.mem.eql(u8, ast.tokenSlice(tokens[i]), "const"))
                    .constant
                else
                    .variable;

                switch (data[i].rhs) {
                    0 => {},
                    else => |rhs| switch (tags[rhs]) {
                        .container_decl,
                        .container_decl_trailing,
                        .container_decl_two,
                        .container_decl_two_trailing,
                        .container_decl_arg,
                        .container_decl_arg_trailing,
                        => {
                            const container_type = ast.tokenSlice(tokens[rhs]);
                            kind = switch (container_type[0]) {
                                's' => .@"struct",
                                'e' => .@"enum",
                                'u' => .@"union",
                                else => continue,
                            };
                        },
                        .tagged_union,
                        .tagged_union_trailing,
                        .tagged_union_two,
                        .tagged_union_two_trailing,
                        .tagged_union_enum_tag,
                        .tagged_union_enum_tag_trailing,
                        => kind = .@"union",
                        .builtin_call_two => if (std.mem.eql(u8, ast.tokenSlice(tokens[rhs]), "@import")) {
                            // Ignore variables of the form
                            //   const foo = @import("foo");
                            // Having these as tags is generally not useful and creates a lot of
                            // redundant noise
                            continue;
                        },
                        .field_access => {
                            // Ignore variables of the form
                            //      const foo = SomeContainer.foo
                            // i.e. when the name of the variable is just an alias to some field
                            const identifier_token = ast.tokenSlice(data[rhs].rhs);
                            if (std.mem.eql(u8, identifier_token, name)) {
                                continue;
                            }
                        },
                        else => {},
                    },
                }
            },
            .container_field_init,
            .container_field_align,
            .container_field,
            => {
                var name = ast.tokenSlice(tokens[i]);
                if (std.mem.eql(u8, name, "_")) {
                    continue;
                }
                if (std.mem.startsWith(u8, name, "@\"")) {
                    name = std.mem.trim(u8, name[1..], "\"");
                }
                ident = name;
                kind = .field;
            },
            else => continue,
        }

        try self.entries.append(allocator, .{
            .ident = try allocator.dupe(u8, ident.?),
            .filename = fname,
            .kind = kind.?,
            .text = try getNodeText(allocator, ast, @intCast(u32, i)),
        });
    }
}

pub fn write(self: *Tags, output: []const u8) !void {
    var contents = std.ArrayList(u8).init(self.arena.allocator());
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
        const text = if (std.mem.indexOfScalar(u8, entry.text, '/')) |_| a: {
            var text = try std.ArrayList(u8).initCapacity(self.arena.allocator(), entry.text.len);
            for (entry.text) |c| {
                if (c == '/') {
                    try text.append('\\');
                }

                try text.append(c);
            }

            break :a text.toOwnedSlice();
        } else entry.text;

        try writer.print("{s}\t{s}\t/{s}/;\"\t{s}\n", .{
            entry.ident,
            entry.filename,
            text,
            @tagName(entry.kind),
        });
    }

    var file = try std.fs.cwd().createFile(output, .{});
    defer file.close();

    try file.writeAll(contents.items);
}

fn getNodeText(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index) ![]const u8 {
    const token_starts = tree.tokens.items(.start);
    const first_token = tree.firstToken(node);
    const last_token = tree.lastToken(node);
    const start = token_starts[first_token];
    const end = token_starts[last_token] + tree.tokenSlice(last_token).len;
    const text = std.mem.sliceTo(tree.source[start..end], '\n');
    const start_of_line = if (start > 0 and tree.source[start - 1] == '\n') "^" else "";
    const end_of_line = if (start + text.len < tree.source.len and tree.source[start + text.len] == '\n')
        "$"
    else
        "";
    return try std.mem.concat(allocator, u8, &.{ start_of_line, text, end_of_line });
}
