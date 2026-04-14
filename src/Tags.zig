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

    fn parse(text: []const u8) ?Kind {
        return if (std.mem.eql(u8, text, "function"))
            .function
        else if (std.mem.eql(u8, text, "field"))
            .field
        else if (std.mem.eql(u8, text, "struct"))
            .@"struct"
        else if (std.mem.eql(u8, text, "enum"))
            .@"enum"
        else if (std.mem.eql(u8, text, "union"))
            .@"union"
        else if (std.mem.eql(u8, text, "variable"))
            .variable
        else if (std.mem.eql(u8, text, "constant"))
            .constant
        else
            null;
    }

    test "Kind.parse" {
        inline for (std.meta.fields(Kind)) |field| {
            const parsed = Kind.parse(field.name) orelse {
                std.debug.print("Kind variant \"{s}\" missing in Kind.parse()\n", .{field.name});
                return error.MissingParseVariant;
            };
            try std.testing.expectEqual(parsed, @as(Kind, @enumFromInt(field.value)));
        }
    }
};

const Entry = struct {
    ident: []const u8,
    filename: []const u8,
    text: []const u8,
    kind: Kind,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.ident);
        allocator.free(self.text);
    }

    fn eql(self: Entry, other: Entry) bool {
        return std.mem.eql(u8, self.ident, other.ident) and
            std.mem.eql(u8, self.filename, other.filename) and
            std.mem.eql(u8, self.text, other.text) and
            self.kind == other.kind;
    }
};

fn OptionallyAllocatedSlice(comptime T: type) type {
    return struct {
        slice: []const T,
        allocated: bool,

        const Self = @This();

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            if (self.allocated) {
                allocator.free(self.slice);
            }
        }
    };
}

allocator: std.mem.Allocator,
entries: EntryList,
visited: std.StringHashMap(void),

/// Static buffer for writing full paths.
///
/// Data in this buffer is duplicated when passed to findTags.
var path_buf: [std.fs.max_path_bytes]u8 = undefined;

pub fn init(allocator: std.mem.Allocator) Tags {
    return Tags{
        .allocator = allocator,
        .entries = .{},
        .visited = std.StringHashMap(void).init(allocator),
    };
}

pub fn deinit(self: *Tags) void {
    for (self.entries.items) |entry| {
        entry.deinit(self.allocator);
    }

    self.entries.deinit(self.allocator);

    var it = self.visited.keyIterator();
    while (it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.visited.deinit();
}

fn readFile(allocator: std.mem.Allocator, fname: []const u8) !?[:0]const u8 {
    const file = try std.fs.cwd().openFile(fname, .{});
    defer file.close();

    const metadata = try file.stat();
    const size = metadata.size;
    if (size == 0) {
        return null;
    }

    if (metadata.kind == .directory) {
        return error.IsDir;
    }

    var array_list = try std.array_list.Managed(u8).initCapacity(allocator, size + 1);
    defer array_list.deinit();
    try file.deprecatedReader().readAllArrayList(&array_list, size + 1);
    return try array_list.toOwnedSliceSentinel(0);
}

fn parseName(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "_")) {
        return null;
    }

    return if (std.mem.startsWith(u8, name, "@\""))
        std.mem.trim(u8, name[1..], "\"")
    else
        name;
}

fn importPath(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) ?[]const u8 {
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) {
        return null;
    }

    var params_buf: [2]std.zig.Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&params_buf, node) orelse return null;
    if (params.len != 1) {
        return null;
    }

    return std.mem.trim(u8, tree.tokenSlice(tree.firstToken(params[0])), "\"");
}

fn containerKind(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) ?Kind {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, node) orelse return null;
    const container_type = tree.tokenSlice(container.ast.main_token);

    return switch (container_type[0]) {
        's' => .@"struct",
        'e' => .@"enum",
        'u' => .@"union",
        else => null,
    };
}

pub fn findTags(self: *Tags, fname: []const u8) anyerror!void {
    const fname_ = try self.allocator.dupe(u8, fname);
    const gop = try self.visited.getOrPut(fname_);
    if (gop.found_existing) {
        // Entry already exists in the visited map, so free the duplicated
        // filename
        self.allocator.free(fname_);
        return;
    }
    gop.value_ptr.* = {};

    const source = try readFile(self.allocator, fname_) orelse return;
    defer self.allocator.free(source);

    var allocator = self.allocator;
    var ast = try std.zig.Ast.parse(allocator, source, .zig);
    defer ast.deinit(allocator);

    const tags = ast.nodes.items(.tag);
    for (tags, 0..) |tag, i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        var ident: ?[]const u8 = null;
        var kind: ?Kind = null;

        switch (tag) {
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                if (importPath(ast, node)) |name| {
                    if (std.mem.endsWith(u8, name, ".zig")) {
                        const dir = std.fs.path.dirname(fname_) orelse continue;
                        const import_fname = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{
                            dir,
                            name,
                        });

                        const resolved = try std.fs.path.resolve(allocator, &.{import_fname});
                        defer allocator.free(resolved);

                        self.findTags(resolved) catch |err| switch (err) {
                            error.FileNotFound => continue,
                            else => return err,
                        };
                    }
                }
                continue;
            },
            .fn_decl => {
                var buffer: [1]std.zig.Ast.Node.Index = undefined;
                const fn_proto = ast.fullFnProto(&buffer, node) orelse continue;
                const name_token = fn_proto.name_token orelse continue;
                ident = ast.tokenSlice(name_token);
                kind = .function;
            },
            .global_var_decl,
            .simple_var_decl,
            .local_var_decl,
            .aligned_var_decl,
            => {
                const var_decl = ast.fullVarDecl(node) orelse continue;
                const name = parseName(ast.tokenSlice(var_decl.ast.mut_token + 1)) orelse continue;

                ident = name;
                kind = if (std.mem.eql(u8, ast.tokenSlice(var_decl.ast.mut_token), "const"))
                    .constant
                else
                    .variable;

                if (var_decl.ast.init_node.unwrap()) |rhs| {
                    if (containerKind(ast, rhs)) |container_kind| {
                        kind = container_kind;
                    } else {
                        switch (ast.nodeTag(rhs)) {
                            .builtin_call,
                            .builtin_call_comma,
                            .builtin_call_two,
                            .builtin_call_two_comma,
                            => if (importPath(ast, rhs) != null) {
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
                                const identifier_token = ast.tokenSlice(ast.nodeData(rhs).node_and_token[1]);
                                if (std.mem.eql(u8, identifier_token, name)) {
                                    continue;
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            .container_field_init,
            .container_field_align,
            .container_field,
            => {
                const field = ast.fullContainerField(node) orelse continue;
                const name = parseName(ast.tokenSlice(field.ast.main_token)) orelse continue;
                ident = name;
                kind = .field;
            },
            else => continue,
        }

        try self.entries.append(allocator, .{
            .ident = try allocator.dupe(u8, ident.?),
            .filename = fname_,
            .kind = kind.?,
            .text = try getNodeText(allocator, ast, node),
        });
    }
}

/// Read tags entries from a tags file
pub fn read(self: *Tags, data: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '!') {
            continue;
        }

        var ident: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var text: ?[]const u8 = null;
        var kind: ?Kind = null;

        var i: usize = 0;
        var fields = std.mem.tokenizeScalar(u8, line, '\t');
        while (fields.next()) |field| : (i += 1) {
            switch (i) {
                0 => ident = field,
                1 => filename = field,
                2 => text = text: {
                    var slice = field;
                    if (slice.len > 0 and slice[0] == '/') {
                        slice = slice[1..];
                    }

                    if (std.mem.lastIndexOf(u8, slice, "/;\"")) |j| {
                        slice = slice[0..j];
                    }

                    break :text slice;
                },
                3 => kind = Kind.parse(field),
                else => break,
            }
        }

        if (ident == null or filename == null or text == null or kind == null) {
            continue;
        }

        ident = try self.allocator.dupe(u8, ident.?);
        errdefer self.allocator.free(ident.?);

        const gop = try self.visited.getOrPut(filename.?);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, filename.?);
            gop.value_ptr.* = {};
        }
        filename = gop.key_ptr.*;

        const unescaped = try unescape(self.allocator, text.?);
        text = if (unescaped.allocated)
            unescaped.slice
        else
            try self.allocator.dupe(u8, unescaped.slice);
        errdefer self.allocator.free(text.?);

        try self.entries.append(self.allocator, .{
            .ident = ident.?,
            .filename = filename.?,
            .text = text.?,
            .kind = kind.?,
        });
    }
}

pub fn write(self: *Tags, allocator: std.mem.Allocator, relative: bool) ![]const u8 {
    var contents = std.array_list.Managed(u8).init(allocator);
    defer contents.deinit();

    var writer = contents.writer();

    try writer.writeAll(
        "!_TAG_FILE_SORTED\t1\t/1 = sorted/\n" ++
            "!_TAG_FILE_ENCODING\tutf-8\n",
    );

    try removeDuplicates(self.allocator, &self.entries);

    const cwd = if (relative)
        try std.fs.realpathAlloc(allocator, ".")
    else
        null;
    defer if (cwd) |c| allocator.free(c);

    // Cache relative paths to avoid recalculating for the same absolute path. If the relative paths
    // option is not enabled this has no cost other than some stack space and a couple of no-op
    // function calls
    var relative_paths = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = relative_paths.valueIterator();
        while (it.next()) |val| allocator.free(val.*);
        relative_paths.deinit();
    }

    for (self.entries.items) |entry| {
        const escaped = try escape(allocator, entry.text);
        defer escaped.deinit(allocator);

        const filename = if (cwd) |c| filename: {
            const gop = try relative_paths.getOrPut(entry.filename);
            if (!gop.found_existing) {
                gop.value_ptr.* = try std.fs.path.relative(allocator, c, entry.filename);
            }

            break :filename gop.value_ptr.*;
        } else entry.filename;

        try writer.print("{s}\t{s}\t/{s}/;\"\t{s}\n", .{
            entry.ident,
            filename,
            escaped.slice,
            @tagName(entry.kind),
        });
    }

    return try contents.toOwnedSlice();
}

/// Remove duplicates from an EntryList in place. Invalidates pointers.
///
/// This function allocates memory equal to the size of `orig`.
/// The items in `orig` are first sorted and unique items are copied to a newly allocated
/// array. The original array is freed and `orig` is updated to use the newly allocated array.
fn removeDuplicates(allocator: std.mem.Allocator, orig: *EntryList) !void {
    std.mem.sort(Entry, orig.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return switch (std.mem.order(u8, a.ident, b.ident)) {
                .lt => true,
                .gt => false,
                .eq => switch (std.mem.order(u8, a.filename, b.filename)) {
                    .lt => true,
                    .gt => false,
                    .eq => std.mem.lessThan(u8, a.text, b.text),
                },
            };
        }
    }.lessThan);

    var deduplicated_entries = try std.array_list.Managed(Entry).initCapacity(allocator, orig.items.len);
    defer deduplicated_entries.deinit();

    var last_unique: usize = 0;
    for (orig.items, 0..) |entry, i| {
        if (i == 0 or !orig.items[last_unique].eql(entry)) {
            deduplicated_entries.appendAssumeCapacity(entry);
            last_unique = i;
        } else {
            entry.deinit(allocator);
        }
    }

    allocator.free(orig.allocatedSlice());
    orig.* = deduplicated_entries.moveToUnmanaged();
}

test "removeDuplicates" {
    var allocator = std.testing.allocator;
    const input = [_]Entry{
        .{
            .ident = try allocator.dupe(u8, "foo"),
            .filename = "foo.zig",
            .text = try allocator.dupe(u8, "hi this is foo"),
            .kind = .variable,
        },
        .{
            .ident = try allocator.dupe(u8, "foo"),
            .filename = "foo.zig",
            .text = try allocator.dupe(u8, "hi this is foo"),
            .kind = .variable,
        },
        .{
            .ident = try allocator.dupe(u8, "bar"),
            .filename = "foo.zig",
            .text = try allocator.dupe(u8, "hi this is bar"),
            .kind = .variable,
        },
        .{
            .ident = try allocator.dupe(u8, "baz"),
            .filename = "baz.zig",
            .text = try allocator.dupe(u8, "hi this is baz"),
            .kind = .function,
        },
        .{
            .ident = try allocator.dupe(u8, "foo"),
            .filename = "foo.zig",
            .text = try allocator.dupe(u8, "hi this is foo"),
            .kind = .variable,
        },
        .{
            .ident = try allocator.dupe(u8, "bar"),
            .filename = "foo.zig",
            .text = try allocator.dupe(u8, "hi this is bar"),
            .kind = .variable,
        },
    };

    var entries = EntryList{};
    try entries.appendSlice(allocator, &input);
    defer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    try removeDuplicates(allocator, &entries);

    try std.testing.expectEqual(@as(usize, 3), entries.items.len);
    try std.testing.expectEqual(input[2], entries.items[0]);
    try std.testing.expectEqual(input[3], entries.items[1]);
    try std.testing.expectEqual(input[0], entries.items[2]);
}

fn getNodeText(
    allocator: std.mem.Allocator,
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) ![]const u8 {
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

fn escape(allocator: std.mem.Allocator, text: []const u8) !OptionallyAllocatedSlice(u8) {
    const escape_chars = "\\/";
    const escaped_length = blk: {
        var count: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfAnyPos(u8, text, start, escape_chars)) |i| {
            count += 1;
            start = i + 1;
        }

        break :blk text.len + count;
    };

    if (text.len == escaped_length) {
        return .{ .slice = text, .allocated = false };
    }

    var escaped = try allocator.alloc(u8, escaped_length);

    var k: usize = 0;
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, escape_chars, c)) |_| {
            escaped[k] = '\\';
            k += 1;
        }

        escaped[k] = c;
        k += 1;
    }

    std.debug.assert(k == escaped_length);

    return .{ .slice = escaped, .allocated = true };
}

fn unescape(allocator: std.mem.Allocator, text: []const u8) !OptionallyAllocatedSlice(u8) {
    const unescaped_length = blk: {
        var count: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, start, '\\')) |i| {
            count += 1;
            start = i + 2;
        }

        break :blk text.len - count;
    };

    if (text.len == unescaped_length) {
        return .{ .slice = text, .allocated = false };
    }

    const unescaped = try allocator.alloc(u8, unescaped_length);

    var k: usize = 0;
    for (unescaped) |*c| {
        if (k < text.len - 1 and text[k] == '\\') {
            k += 1;
        }

        c.* = text[k];
        k += 1;
    }

    std.debug.assert(k == text.len);

    return .{ .slice = unescaped, .allocated = true };
}

test "escape and unescape" {
    const allocator = std.testing.allocator;

    {
        const original = "and/or\\/";
        const escaped = try escape(allocator, original);
        defer escaped.deinit(allocator);

        const unescaped = try unescape(allocator, escaped.slice);
        defer unescaped.deinit(allocator);

        try std.testing.expectEqualStrings("and\\/or\\\\\\/", escaped.slice);
        try std.testing.expectEqualStrings(original, unescaped.slice);
    }

    {
        const original = "pathological text with trailing backslash\\";
        const escaped = try escape(allocator, original);
        defer escaped.deinit(allocator);

        const unescaped = try unescape(allocator, escaped.slice);
        defer unescaped.deinit(allocator);

        try std.testing.expectEqualStrings("pathological text with trailing backslash\\\\", escaped.slice);
        try std.testing.expectEqualStrings(original, unescaped.slice);
    }

    {
        // No allocation should occur when there is nothing to escape
        const a = std.testing.failing_allocator;

        const original = "hello world";
        const escaped = try escape(a, original);
        defer escaped.deinit(a);

        const unescaped = try unescape(allocator, escaped.slice);
        defer unescaped.deinit(a);

        try std.testing.expectEqualStrings(original, escaped.slice);
        try std.testing.expectEqualStrings(original, unescaped.slice);
    }
}

test "Tags.findTags" {
    var test_dir = try std.fs.cwd().makeOpenPath("test", .{});
    defer {
        test_dir.close();
        std.fs.cwd().deleteTree("test") catch unreachable;
    }

    const a_src =
        \\const b = @import("b.zig");
        \\
        \\const MyEnum = enum {
        \\    a,
        \\    b,
        \\};
        \\
        \\const MyStruct = struct {
        \\    c: u8,
        \\    d: u8,
        \\};
        \\
        \\const MyUnion = union(enum) {
        \\    e: void,
        \\    f: u32,
        \\};
        \\
        \\fn myFunction(s: MyStruct, e: MyEnum, u: MyUnion) u8 {
        \\    const x = switch (e) {
        \\        .a => s.d,
        \\        .b => s.c,
        \\    };
        \\
        \\    const y = switch (u) {
        \\        .e => null,
        \\        .f => |f| f,
        \\    };
        \\
        \\    if (x > y) {
        \\        return x;
        \\    }
        \\
        \\    return b.anotherFunction(y);
        \\}
        \\
    ;

    const b_src =
        \\fn anotherFunction(x: u8) u8 {
        \\    var y = x + 1;
        \\    return y * 2;
        \\}
        \\
    ;

    try test_dir.writeFile(.{
        .sub_path = "a.zig",
        .data = a_src,
    });
    try test_dir.writeFile(.{
        .sub_path = "b.zig",
        .data = b_src,
    });

    var tags = Tags.init(std.testing.allocator);
    defer tags.deinit();

    const full_path = try test_dir.realpathAlloc(std.testing.allocator, "a.zig");
    defer std.testing.allocator.free(full_path);
    try tags.findTags(full_path);

    const cwd = try std.fs.cwd().openDir(".", .{});
    try test_dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    const actual = try tags.write(std.testing.allocator, true);
    defer std.testing.allocator.free(actual);

    const golden =
        "!_TAG_FILE_SORTED\t1\t/1 = sorted/\n" ++
        "!_TAG_FILE_ENCODING\tutf-8\n" ++
        "MyEnum\ta.zig\t/^const MyEnum = enum {$/;\"\tenum\n" ++
        "MyStruct\ta.zig\t/^const MyStruct = struct {$/;\"\tstruct\n" ++
        "MyUnion\ta.zig\t/^const MyUnion = union(enum) {$/;\"\tunion\n" ++
        "a\ta.zig\t/a/;\"\tfield\n" ++
        "anotherFunction\tb.zig\t/fn anotherFunction(x: u8) u8 {$/;\"\tfunction\n" ++
        "b\ta.zig\t/b/;\"\tfield\n" ++
        "c\ta.zig\t/c: u8/;\"\tfield\n" ++
        "d\ta.zig\t/d: u8/;\"\tfield\n" ++
        "e\ta.zig\t/e: void/;\"\tfield\n" ++
        "f\ta.zig\t/f: u32/;\"\tfield\n" ++
        "myFunction\ta.zig\t/^fn myFunction(s: MyStruct, e: MyEnum, u: MyUnion) u8 {$/;\"\tfunction\n" ++
        "x\ta.zig\t/const x = switch (e) {$/;\"\tconstant\n" ++
        "y\ta.zig\t/const y = switch (u) {$/;\"\tconstant\n" ++
        "y\tb.zig\t/var y = x + 1/;\"\tvariable\n";

    try std.testing.expectEqualStrings(golden, actual);
}

test "Tags.findTags skips import aliases and same-name field aliases" {
    var test_dir = try std.fs.cwd().makeOpenPath("test-alias-filter", .{});
    defer {
        test_dir.close();
        std.fs.cwd().deleteTree("test-alias-filter") catch unreachable;
    }

    const source =
        \\const imported = @import("dep.zig");
        \\
        \\const Wrapper = struct {
        \\    value: u8,
        \\};
        \\
        \\const value = Wrapper.value;
        \\const renamed = Wrapper.value;
        \\
    ;

    const dep_source =
        \\pub fn helper() void {}
        \\
    ;

    try test_dir.writeFile(.{
        .sub_path = "root.zig",
        .data = source,
    });
    try test_dir.writeFile(.{
        .sub_path = "dep.zig",
        .data = dep_source,
    });

    var tags = Tags.init(std.testing.allocator);
    defer tags.deinit();

    const full_path = try test_dir.realpathAlloc(std.testing.allocator, "root.zig");
    defer std.testing.allocator.free(full_path);
    try tags.findTags(full_path);

    const actual = try tags.write(std.testing.allocator, true);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, actual, "imported\ttest-alias-filter/root.zig\t/"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, actual, "value\ttest-alias-filter/root.zig\t/^const value = Wrapper.value/;\"\tconstant\n"));
    try std.testing.expect(std.mem.indexOf(u8, actual, "renamed\ttest-alias-filter/root.zig\t/^const renamed = Wrapper.value/;\"\tconstant\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "helper\ttest-alias-filter/dep.zig\t/pub fn helper() void {}$/;\"\tfunction\n") != null);
}

test "Tags.read" {
    const input =
        "!_TAG_FILE_SORTED\t1\t/1 = sorted/\n" ++
        "!_TAG_FILE_ENCODING\tutf-8\n" ++
        "MyEnum\ta.zig\t/^const MyEnum = enum {$/;\"\tenum\n" ++
        "MyStruct\ta.zig\t/^const MyStruct = struct {$/;\"\tstruct\n" ++
        "MyUnion\ta.zig\t/^const MyUnion = union(enum) {$/;\"\tunion\n" ++
        "a\ta.zig\t/a/;\"\tfield\n" ++
        "anotherFunction\tb.zig\t/fn anotherFunction(x: u8) u8 {$/;\"\tfunction\n" ++
        "b\ta.zig\t/b/;\"\tfield\n" ++
        "c\ta.zig\t/c: u8/;\"\tfield\n" ++
        "d\ta.zig\t/d: u8/;\"\tfield\n" ++
        "e\ta.zig\t/e: void/;\"\tfield\n" ++
        "f\ta.zig\t/f: u32/;\"\tfield\n" ++
        "myFunction\ta.zig\t/^fn myFunction(s: MyStruct, e: MyEnum, u: MyUnion) u8 {$/;\"\tfunction\n" ++
        "x\ta.zig\t/const x = switch (e) {$/;\"\tconstant\n" ++
        "y\ta.zig\t/const y = switch (u) {$/;\"\tconstant\n" ++
        "y\tb.zig\t/var y = x + 1/;\"\tvariable\n";

    var tags = Tags.init(std.testing.allocator);
    defer tags.deinit();

    try tags.read(input);
    const output = try tags.write(std.testing.allocator, true);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings(input, output);
}
