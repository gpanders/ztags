const std = @import("std");

const version: std.SemanticVersion = .{ .major = 1, .minor = 0, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztags",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "name", exe.name);
    options.addOption([]const u8, "version", b.fmt("{d}.{d}.{d}", .{
        version.major,
        version.minor,
        version.patch,
    }));

    exe.root_module.addOptions("config", options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    unit_tests.root_module.addOptions("config", options);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const docs_cmd = b.addSystemCommand(&.{"scdoc"});
    docs_cmd.setStdIn(.{ .lazy_path = b.path("ztags.1.scd") });
    const docs_out = docs_cmd.captureStdOut();
    const docs = b.addInstallFileWithDir(docs_out, .{
        .custom = b.pathJoin(&.{ "share", "man", "man1" }),
    }, "ztags.1");

    const docs_step = b.step("docs", "Build documentation");
    docs_step.dependOn(&docs.step);
}
