# Changelog

## [Unreleased]

### Added

- `patched(b, upstream, patches)`: a package's own `git format-patch` series over a hash-pinned upstream, applied by its build into the tree it compiles. Every file in the patches directory is applied, in the byte order of the names; each hunk only at the line it names, its context and removed lines the file's bytes, line endings included, with no fuzz and no offset. Files are modified, created and deleted, and renamed or copied with their hunks. A mode change, a binary change, a link and a path out of the tree are refused by name, and a patch that does not apply fails the build naming the patch, the file, the hunk and the line. The step is one Run step of retrofit's program, whose inputs are the upstream and each patch, so Zig's cache reruns it only when one of them changes.

- A property for the README's promises over generated series: changes made exactly (files modified, created and deleted, LF or CRLF), every other file the upstream's, and one byte of the upstream changed under a hunk refusing it. It fails on each of three planted faults.

### Changed

- Pins aegis dc3ed602, still 0.2.4; development on preflight's ci-standard 0990716 and glint 0.8, and shakedown ed5a873. The patches and the upstream's files are read in one input seam (`src/input.zig`).
- The README states retrofit's stability policy: 0.x, tracking Zig 0.17.x; a breaking change only in a minor release, with its CHANGELOG entry; a patch release never breaks.
- Pins aegis breaking-0.3 (a34e694), the 0.3.0 line the family is on, where it pinned aegis 0.2.3, and shakedown main (4979fa9) for the tests. retrofit builds on them unchanged.
