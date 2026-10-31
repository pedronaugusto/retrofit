# Changelog

## [Unreleased]

### Added

- `patched(b, upstream, patches)`: a package's own `git format-patch` series over a hash-pinned upstream, applied by its build into the tree it compiles. Every file in the patches directory is applied, in the byte order of the names; each hunk only at the line it names, its context and removed lines the file's bytes, line endings included, with no fuzz and no offset. Files are modified, created and deleted, and renamed or copied with their hunks. A mode change, a binary change, a link and a path out of the tree are refused by name, and a patch that does not apply fails the build naming the patch, the file, the hunk and the line. The step is one Run step of retrofit's program, whose inputs are the upstream and each patch, so Zig's cache reruns it only when one of them changes.
