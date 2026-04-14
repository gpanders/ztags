const std = @import("std");
const zzdoc = @import("zzdoc");

const version: std.SemanticVersion = .{ .major = 1, .minor = 0, .patch = 1 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ztags",
        .root_module = root_module,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "name", exe.name);
    options.addOption([]const u8, "version", b.fmt("{d}.{d}.{d}", .{
        version.major,
        version.minor,
        version.patch,
    }));

    root_module.addOptions("config", options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const manpages = zzdoc.addManpageStep(b, .{
        .root_doc_dir = b.path("."),
    });
    const install_manpages = manpages.addInstallStep(.{});
    b.getInstallStep().dependOn(&install_manpages.step);

    const docs_step = b.step("docs", "Build documentation");
    docs_step.dependOn(&install_manpages.step);
}
