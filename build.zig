const std = @import("std");

const tags = @import("src/tags.zig");
pub usingnamespace tags;

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("example", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    var tags_step = tags.addTags(b, "tags");
    tags_step.addSource(exe);
}
