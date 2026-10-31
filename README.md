# retrofit

A package's own patches over a pinned upstream, applied by its build, exactly.

The upstream (a C library's repository, a set of headers) is a hash-pinned dependency
in `build.zig.zon`, so Zig proves it is the upstream. The package's changes to it are a
`git format-patch` series in a directory of the package. Its build compiles only the
tree retrofit makes from the two: the upstream plus exactly those patches, proven on
every build, with no copy of the upstream to keep in step and no vendor check beside it.

## Use

```zig
// build.zig.zon: .dependencies = .{ .retrofit = .{ … }, .cgltf = .{ .url = …, .hash = … } }
const retrofit = @import("retrofit");

pub fn build(b: *std.Build) void {
    const cgltf = retrofit.patched(b, b.dependency("cgltf", .{}).path(""), b.path("patches"));
    module.addIncludePath(cgltf);
    module.addCSourceFiles(.{ .root = cgltf, .files = &.{"cgltf.c"} });
}
```

`patched(b, upstream, patches)` returns the patched tree as a `LazyPath`. It adds one Run
step of retrofit's program, built for the build's host. Its inputs are the upstream and
each patch, so Zig's own cache reruns it when a patch changes, and never otherwise.

## The series

Each patch is a mail, as `git format-patch` writes one: a message saying what it fixes
and why, with its evidence, then the diff. The files' names are the order (`0001-…`,
`0002-…`), so there is no list to keep. Every file in the directory must be a `.patch`, so
nothing there is left out unseen. Refresh a series with git: apply it to a checkout of the
upstream with `git am`, edit, and write it again with `git format-patch`.

Keep the patches as git writes them, with `*.patch -text` in `.gitattributes`, so no
checkout translates their line endings.

## Exactly

Each hunk applies at the line it names. Its context and removed lines must be the file's
bytes, line endings included: an upstream with CRLF stays CRLF. There is no fuzz and no
offset. When the pin moves, the series applies again or the build fails, naming the
patch, the file, the hunk and the line that differs.

A patch modifies, creates and deletes files. A rename or a copy applies as the file
written at its new path with the hunks applied (and, for a rename, the old one deleted).
A mode change, a binary change, a link and a path out of the tree are refused by name.

## Development

retrofit is developed with [bay](https://github.com/pedronaugusto/bay): `bay dev test`
runs the tests, a consumer's build through `patched` and a fuzz target on the patch
reader; `bay ci` is the gate.

## License

MIT
