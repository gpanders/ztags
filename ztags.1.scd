ztags(1)

# NAME

ztags - generate tags files from Zig source code

# SYNOPSIS

*ztags* [-a] [-r] [-o OUTPUT] FILES...

# DESCRIPTION

*ztags* is a replacement for the *ctags(1)* tool specifically for working with
Zig source code. Unlike *ctags(1)*, *ztags* does not use regex based matching
but instead parses the abstract syntax tree of the provided Zig sources. This
results in fewer false positives and better matching.

Import statements of the form _@import("foo.zig")_ are followed and parsed. Only
imports using relative file paths are followed: import statements of the form
_@import("foo")_ are not followed because *ztags* does not have enough
information at runtime to determine the source file location of the _foo_
package.

The following options are available:

*-a*
	Append tags to an existing _tags_ file instead of overwriting. Duplicate
	tags are removed.

*-r*
	Use paths relative to the current working directory in the generated
	_tags_ file. This is equivalent to *--tag-relative=no* in *ctags(1)*.

*-o* _OUTPUT_
	Write tags to _OUTPUT_ (default is _tags_ in the current directory).

# EXAMPLES

## Generate tags for the Zig standard library

Run *ztags* on _std.zig_ in Zig's installation directory. Example:

	ztags -o ~/.cache/tags/zig.tags /usr/local/lib/zig/lib/std.zig

This will generate a separate tags file just for standard library tags.
Alternatively, analyze the standard library alongside your project source code
and include all tags in the same file:

	ztags src/main.zig /usr/local/lib/zig/lib/std.zig

# SEE ALSO

*ctags(1)*

# CONTRIBUTE

Report bugs and send patches to the mailing list ~gpanders/ztags@lists.sr.ht.

# AUTHOR

Gregory Anders <greg@gpanders.com>
