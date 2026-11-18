# Design

retrofit applies a package's own patches over a pinned upstream, in the
package's build. The upstream (a C library, a set of headers) is a hash-pinned
`build.zig.zon` dependency, so Zig proves it is the upstream. The package's
changes are a `git format-patch` series in a directory of the package. The build
compiles only the tree retrofit makes from the two.

It is not part of bay: a package's consumers must not fetch a package manager,
or couple to its version, to build. bay depends on retrofit no more than
retrofit on bay; `bay outdated` only counts the series it finds in
`patches/<key>` beside a pin.

## Decisions

- **A series, ordered by its names.** Each patch is a mail: a message saying
  what it fixes and why, then the diff. `0001-`, `0002-` are the order, so
  there is no manifest to keep in step. The directory is listed when the build
  is configured, in byte order, and every entry must be a `.patch`, so nothing
  in it is left out unseen. Maintainers refresh a series with git (`am`, edit,
  `format-patch`).
- **Exact apply is the proof, on every build.** Each hunk applies only at the
  line it names, its context and removed lines the file's bytes. There is no
  fuzz and no offset, and no line ending is translated: a CRLF upstream stays
  CRLF, and patches are kept `-text`. The tree exists only as the upstream plus
  exactly those patches, so there is no vendor check beside it: a moved pin
  applies again, or the build fails naming the patch, the file, the hunk and
  the line that differs.
- **Zig's Run-step cache, none of retrofit's own.** `patched(b, upstream,
  patches) LazyPath` adds one Run step of retrofit's program, built for the
  host. Its inputs are the upstream directory and each patch as a file
  argument, so a changed patch reruns the step and nothing else does.
- **What a patch may do.** Modify, create and delete files. A rename or copy
  writes the new path with its hunks applied (and, for a rename, deletes the
  old one). A mode change, a binary change, a link and a path out of the tree
  are refused by name.

## Parts

- `build.zig`: `patched`, which lists the series and wires the Run step.
- `src/series.zig`: one patch read as the changes it makes. parallax parses the
  unified diff (`parallax.patch.parse`) and keeps each file's git headers;
  retrofit reads those headers (created, deleted, renamed, copied) and refuses
  what it does not apply. A patch enters as `aegis.input.Untrusted`; limits:
  64 MiB a patch, 65536 files, 4096-byte paths of at most 256 components.
- `src/tree.zig`: the upstream copied whole, then each patch applied to the copy
  in order with `parallax.patch.apply` at `.fuzz = 0, .max_offset = 0,
  .rejects = .fail`. A file a patch changes is read up to 1 GiB.
- `src/input.zig`: the one input seam; the patches and the upstream's files are
  read whole under their limits there.
- `src/main.zig`: the program the Run step runs.

## Tests

The tests run a consumer's build through `patched` (`test/consumer`, with a
stale patch it must refuse), apply series to trees on shakedown's `FaultIo`
(a fault while copying or writing is returned, never a tree that is not the
upstream's), refuse moved hunks and changed context, keep a CRLF upstream's
carriage returns as bytes, refuse binary and mode changes and paths out of the
tree, fuzz the patch reader, and hold a property over generated series: changes
made exactly, every other file the upstream's, and one byte of the upstream
changed under a hunk refusing it.
