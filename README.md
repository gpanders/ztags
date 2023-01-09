# ztags

Generate tags files for Zig projects.

Unlike `ctags`, this does not use regular expressions, but instead analyzes the
abstract syntax tree of the source code.

## Building

Simply clone this repository and build with `zig build`. This will produce a
`Debug` build by default, which generates useful error messages but can be a
bit slow. To build a release build use

```console
$ zig build -Drelease-safe
```

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
sourcehut account by sending a [plain text email](useplaintext.email) to
[~gpanders/ztags@todo.sr.ht](mailto://~gpanders/ztags@todo.sr.ht).

Send patches to [~gpanders/ztags@lists.sr.ht][list] or open a pull request on
[GitHub][github].

[list]: https://lists.sr.ht/~gpanders/ztags
[github]: https://github.com/gpanders/ztags
[tickets]: https://todo.sr.ht/~gpanders/ztags


## License

MIT
