const std = @import("std");

const EntryList = std.MultiArrayList(Entry);

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

const TagsStep = struct {
    builder: *std.build.Builder,
    step: std.build.Step,
    entries: EntryList,
    output: []const u8,
    sources: std.ArrayList(*std.build.LibExeObjStep),
    visited: std.StringHashMap([]const u8),

    pub fn init(b: *std.build.Builder, output: []const u8) *TagsStep {
        const self = b.allocator.create(TagsStep) catch unreachable;
        self.* = TagsStep{
            .builder = b,
            .output = b.allocator.dupe(u8, output) catch unreachable,
            .step = std.build.Step.init(.custom, "tags", b.allocator, make),
            .sources = std.ArrayList(*std.build.LibExeObjStep).init(b.allocator),
            .entries = .{},
            .visited = std.StringHashMap([]const u8).init(b.allocator),
        };
        return self;
    }

    pub fn addSource(self: *TagsStep, lib_exe_obj: *std.build.LibExeObjStep) void {
        self.sources.append(lib_exe_obj) catch unreachable;
    }

    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(TagsStep, "step", step);
        const builder = self.builder;
        for (self.sources.items) |src| {
            const root_src = src.root_src orelse continue;
            const path = root_src.getPath(builder);
            try self.findTags(path, src.packages.items);
        }

        try self.write();
    }

    fn findTags(self: *TagsStep, fname: []const u8, pkgs: []std.build.Pkg) anyerror!void {
        const gop = try self.visited.getOrPut(fname);
        if (gop.found_existing) {
            return;
        }
        gop.value_ptr.* = fname;

        var allocator = self.builder.allocator;
        var file = try std.fs.cwd().openFile(fname, .{});
        defer file.close();

        var source = try std.os.mmap(null, try file.getEndPos(), std.os.PROT.READ, std.os.MAP.SHARED, file.handle, 0);
        defer std.os.munmap(source);

        var ast = try std.zig.parse(allocator, std.meta.assumeSentinel(source, 0));
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
                            const import_fname = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
                            self.findTags(import_fname, pkgs) catch |err| switch (err) {
                                error.FileNotFound => continue,
                                else => return err,
                            };
                        } else for (pkgs) |pkg| {
                            if (std.mem.eql(u8, pkg.name, name)) {
                                try self.findTags(pkg.source.getPath(self.builder), pkgs);
                            }
                        }
                    }
                },
                .fn_decl => {
                    const name_token = tokens[i] + 1;
                    const name = ast.tokenSlice(name_token);
                    const offset = ast.tokens.items(.start)[name_token];
                    const loc = std.zig.findLineColumn(source, offset);
                    try self.entries.append(allocator, .{
                        .ident = try allocator.dupe(u8, name),
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
                    const name = ast.tokenSlice(name_token);
                    if (std.mem.eql(u8, name, "_")) {
                        continue;
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
                    try self.entries.append(allocator, .{
                        .ident = try allocator.dupe(u8, name),
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
                    const name = ast.tokenSlice(name_token);
                    if (std.mem.eql(u8, name, "_")) {
                        continue;
                    }
                    const offset = ast.tokens.items(.start)[name_token];
                    const loc = std.zig.findLineColumn(source, offset);
                    try self.entries.append(allocator, .{
                        .ident = try allocator.dupe(u8, name),
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

    pub fn write(self: *TagsStep) !void {
        const output = if (self.builder.args) |args|
            args[0]
        else
            self.output;

        var file = try std.fs.cwd().createFile(output, .{});
        defer file.close();

        var buffered_writer = std.io.bufferedWriter(file.writer());

        try buffered_writer.writer().writeAll(
            \\!_TAG_FILE_SORTED	1	/1 = sorted/
            \\!_TAG_FILE_ENCODING	utf-8	
            \\
        );

        self.entries.sort(struct {
            entries: *EntryList,
            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                const idents = ctx.entries.items(.ident);
                const a = idents[a_index];
                const b = idents[b_index];
                return std.mem.lessThan(u8, a, b);
            }
        }{ .entries = &self.entries });

        const idents = self.entries.items(.ident);
        const filenames = self.entries.items(.filename);
        const locs = self.entries.items(.loc);
        const kinds = self.entries.items(.kind);
        for (idents) |ident, i| {
            const filename = filenames[i];
            const loc = locs[i];
            const kind = kinds[i];
            try buffered_writer.writer().print("{s}\t{s}\tcall cursor({d}, {d})|;\"\t{s}\n", .{
                ident,
                filename,
                loc.line + 1,
                loc.column + 1,
                @tagName(kind),
            });
        }

        try buffered_writer.flush();
    }
};

/// Add a 'tags' build step. "output" is the default filename that tags will be written to. The output file can be changed by passing an argument to `zig build`:
///
///     zig build test -- .git/tags
pub fn addTags(b: *std.build.Builder, output: []const u8) *TagsStep {
    var tags_step = TagsStep.init(b, output);
    const top_level_tags_step = b.step("tags", "Build tags file");
    top_level_tags_step.dependOn(&tags_step.step);
    return tags_step;
}
