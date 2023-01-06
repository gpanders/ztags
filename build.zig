const std = @import("std");

const DiffStep = struct {
    step: std.build.Step,
    builder: *std.build.Builder,
    a: std.build.FileSource,
    b: std.build.FileSource,

    fn init(
        builder: *std.build.Builder,
        a: std.build.FileSource,
        b: std.build.FileSource,
    ) *DiffStep {
        const self = builder.allocator.create(DiffStep) catch unreachable;
        self.* = .{
            .builder = builder,
            .a = a.dupe(builder),
            .b = b.dupe(builder),
            .step = std.build.Step.init(.custom, "Diff", builder.allocator, make),
        };

        return self;
    }

    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(DiffStep, "step", step);
        const a_path = self.a.getPath(self.builder);
        const b_path = self.b.getPath(self.builder);
        const a = try std.fs.cwd().readFileAlloc(self.builder.allocator, a_path, 20 * 1024 * 1024);
        const b = try std.fs.cwd().readFileAlloc(self.builder.allocator, b_path, 20 * 1024 * 1024);

        if (std.mem.indexOfDiff(u8, a, b)) |index| {
            std.debug.print("{s} and {s} differ at byte {}\n", .{ a_path, b_path, index });
            return error.FilesDiffer;
        }
    }
};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("ztags", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
