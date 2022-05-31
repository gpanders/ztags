# zig-ctags

Generate a tags file for Zig source code.

Unlike `ctags`, this does not use regular expressions, but instead analyzes the
abstract syntax tree of the source code.

## Usage

This is a build module, meaning it is meant to be used in the `build.zig` of another project.

Example:

```zig
const std = @import("std");

const tags = @import("deps/zig-tags/build.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("hello", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    var tags_step = tags.addTags(b, "tags");
    tags_step.addSource(exe);
}
```

Tags can then be built using

    zig build tags

The default filename of the tags file is the second argument to `addTags` (`"tags"` in the example above). This can be overriden on the commandline by passing an optional parameter:

    zig build tags -- .git/tags

You can also make the tags file build automatically by adding a dependency to the install step:

```zig
var tags_step = tags.addTags(b, "tags");
tags_step.addSource(exe);
b.getInstallStep().dependOn(&tags_step.step);
```

Now the `tags` file will be automatically created (and updated) each time `zig build` is run.

## Limitations

At present, `zig-tags` does not follow `@import` statements of builtin packages (i.e. `std`).

## License

MIT
