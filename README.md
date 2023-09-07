# ztags

Generate tags files for Zig projects.

Unlike `ctags`, this does not use regular expressions, but instead analyzes the
abstract syntax tree of the source code.

## Building

Simply clone this repository and build with `zig build`. This will produce a
`Debug` build by default, which generates useful error messages but can be a
bit slow. To build a release build use

```console
$ zig build -Doptimize=ReleaseSafe
```

To build the man page (requires [scdoc][]), run

```console
$ zig build docs
```

This will install the man page to `share/man/man1/ztags.1` relative to the
prefix given with `-p`/`--prefix` (default `zig-out`).

To build and install both `ztags` and the man page to `$PREFIX` simultaneously,
use

```console
$ zig build -Doptimize=ReleaseSafe -p $PREFIX install docs
```

The `master` branch tracks Zig `HEAD`. Use the `0.11.0` branch if using a
stable release.

[scdoc]: https://sr.ht/~sircmpwn/scdoc/

## Usage

Pass a source file to the `ztags` executable. `ztags` will find `@import`
statements for relative files (i.e. any imports that end with `.zig`) and
recursively index those files too.

Packages (imports that are not a relative path, but a package name such as
`@import("foo")`) are not followed, as package information is not available at
runtime. Instead, pass the root source file of each package as an additional
command line argument.

For example, the entire Zig standard library can be indexed using:

```console
$ ztags /path/to/zig/std/std.zig
```

The following "kinds" are supported:

- `enum`
- `field`
- `struct`
- `constant`
- `function`
- `variable`
- `union`

## Contributing

Have a question, comment, or feature request? Send an email to the [mailing
list][list].

Report bugs on the [ticket tracker][tickets]. You can file a ticket without a
sourcehut account by sending a [plain text email](https://useplaintext.email) to
[~gpanders/ztags@todo.sr.ht](mailto://~gpanders/ztags@todo.sr.ht).

[Send patches][git-send-email] to [~gpanders/ztags@lists.sr.ht][list] or open a
pull request on [GitHub][github].

[list]: https://lists.sr.ht/~gpanders/ztags
[github]: https://github.com/gpanders/ztags
[tickets]: https://todo.sr.ht/~gpanders/ztags
[git-send-email]: https://git-send-email.io/


## License

MIT
