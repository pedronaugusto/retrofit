//! The patched tree: the upstream's tree copied whole, then each patch of the
//! series applied to the copy in order, each hunk exactly where it says (parallax's
//! apply with no fuzz and no offset). Bytes are copied and compared as they are:
//! no line ending is translated.

const std = @import("std");
const aegis = @import("aegis");
const parallax = @import("parallax");
const series = @import("series.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The largest file of the upstream a patch changes.
pub const file_bytes: aegis.units.Bytes(u64) = .fromRaw(1 << 30);

pub const Error = series.Error || error{
    /// An entry of the upstream that is neither a file nor a directory (a link, a device).
    UnsupportedEntry,
    /// A change reads a file the tree does not hold.
    MissingFile,
    /// A change creates a file, or renames or copies one onto a path, the tree holds already.
    FileExists,
    /// A hunk does not apply exactly where it says.
    HunkFailed,
    /// A deletion leaves lines of the file.
    DeletionLeavesContent,
    /// parallax was handed results that do not match the hunks: never, as one slot is made per hunk.
    InvalidResults,
} || Io.Dir.OpenError || Io.Dir.CreateDirPathError || Io.Dir.CopyFileError || Io.Dir.DeleteFileError || Io.Dir.DeleteTreeError || Io.Dir.WriteFileError || aegis.own.ReadFileError || Io.Writer.Error;

/// Why the tree could not be made: the message names the patch, the file and the hunk.
pub const Diagnostic = struct { message: []const u8 = "" };

/// Copies `upstream`'s tree into `out` (made empty first) and applies `patches`, each a
/// path to a patch, in the order given.
pub fn make(io: Io, gpa: Allocator, upstream: Io.Dir, out: Io.Dir, patches: []const []const u8, diagnostic: *Diagnostic) Error!void {
    try copy(io, gpa, upstream, out, diagnostic);
    for (patches) |path| {
        const name = std.fs.path.basename(path);
        const bytes = try aegis.own.readFile(io, Io.Dir.cwd(), path, gpa, series.limits.patch_bytes);
        defer gpa.free(bytes);
        var read_diagnostic: series.Diagnostic = .{};
        var patch = series.read(gpa, .init(bytes), &read_diagnostic) catch |err| {
            diagnostic.message = gpa.print("{s}: {s}", .{ name, read_diagnostic.message }) catch "";
            return err;
        };
        defer patch.deinit();
        for (patch.changes) |change| try applyChange(io, gpa, out, name, change, diagnostic);
    }
}

/// Copies every file and directory of `from` into `to`, which it empties first.
pub fn copy(io: Io, gpa: Allocator, from: Io.Dir, to: Io.Dir, diagnostic: *Diagnostic) Error!void {
    var walker = try from.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try to.createDirPath(io, entry.path),
        .file => try from.copyFile(entry.path, to, entry.path, io, .{}),
        else => {
            diagnostic.message = gpa.print("{s} in the upstream is a {t}: only files and directories are copied", .{ entry.path, entry.kind }) catch "";
            return error.UnsupportedEntry;
        },
    };
}

fn refuse(gpa: Allocator, diagnostic: *Diagnostic, err: Error, comptime format: []const u8, args: anytype) Error {
    diagnostic.message = gpa.print(format, args) catch "";
    return err;
}

/// Applies one change of the patch `name` to the tree in `dir`.
fn applyChange(io: Io, gpa: Allocator, dir: Io.Dir, name: []const u8, change: series.Change, diagnostic: *Diagnostic) Error!void {
    const base: []u8 = if (change.from) |from| aegis.own.readFile(io, dir, try native(gpa, from), gpa, file_bytes) catch |err| switch (err) {
        error.FileNotFound => return refuse(gpa, diagnostic, error.MissingFile, "{s}: {s} is not in the tree", .{ name, from.bytes }),
        else => |e| return e,
    } else try gpa.alloc(u8, 0);
    defer gpa.free(base);
    if (change.to) |to| if (change.kind != .modify) {
        if (dir.access(io, try native(gpa, to), .{})) |_| {
            return refuse(gpa, diagnostic, error.FileExists, "{s}: {s} is in the tree already, and the patch makes it", .{ name, to.bytes });
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    };
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const results = try gpa.alloc(parallax.patch.HunkResult, change.file.hunks.len);
    defer gpa.free(results);
    parallax.patch.apply(gpa, &out.writer, base, change.file, .{ .fuzz = 0, .max_offset = 0, .rejects = .fail }, results) catch |err| switch (err) {
        error.HunkFailed => {
            const at = for (results, 0..) |result, i| {
                if (result == .rejected) break i;
            } else 0;
            const hunk = change.file.hunks[at];
            return refuse(gpa, diagnostic, error.HunkFailed, "{s}: {s}: hunk {d} `@@ -{d},{d} +{d},{d} @@` does not apply at line {d}: {s}", .{ name, change.path(), at + 1, hunk.old_start, hunk.old_len, hunk.new_start, hunk.new_len, hunk.old_start, try mismatch(gpa, base, hunk) });
        },
        error.InputTooLarge => return refuse(gpa, diagnostic, error.HunkFailed, "{s}: {s}: the file is too large to apply to", .{ name, change.path() }),
        error.OutOfMemory, error.WriteFailed, error.InvalidResults => |e| return e,
    };
    const result = out.written();
    switch (change.kind) {
        .delete => {
            if (result.len != 0) return refuse(gpa, diagnostic, error.DeletionLeavesContent, "{s}: deletes {s} but leaves {d} bytes of it", .{ name, change.from.?.bytes, result.len });
            try dir.deleteFile(io, try native(gpa, change.from.?));
            return;
        },
        .modify, .create, .rename, .copy => {},
    }
    const to = try native(gpa, change.to.?);
    if (std.fs.path.dirname(to)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = to, .data = result });
    if (change.kind == .rename) try dir.deleteFile(io, try native(gpa, change.from.?));
}

/// What the file holds where a hunk's first context or removed line differs from it.
fn mismatch(gpa: Allocator, base: []const u8, hunk: parallax.patch.Hunk) Allocator.Error![]const u8 {
    var lines = std.mem.splitScalar(u8, base, '\n');
    var number: u32 = 1;
    // An empty range names the line before it.
    const first = if (hunk.old_len == 0) hunk.old_start + 1 else hunk.old_start;
    while (number < first) : (number += 1) _ = lines.next() orelse break;
    for (hunk.lines) |line| {
        if (line.kind == .added) continue;
        const expected = std.mem.trimEnd(u8, line.text, "\n");
        const found = lines.next() orelse return gpa.print("the file ends before line {d}, which the patch expects as `{f}`", .{ number, std.zig.fmtString(expected) });
        if (!std.mem.eql(u8, found, expected)) {
            const endings = std.mem.eql(u8, std.mem.trimEnd(u8, found, "\r"), std.mem.trimEnd(u8, expected, "\r"));
            return gpa.print("line {d} is `{f}`, the patch expects `{f}`{s}", .{ number, std.zig.fmtString(found), std.zig.fmtString(expected), if (endings) " (their line endings differ: keep the patch as git wrote it, `*.patch -text` in .gitattributes)" else "" });
        }
        number += 1;
    }
    return gpa.print("its lines match there, but a hunk before it moved what follows", .{});
}

/// A patch's `/`-separated path as this host spells it.
fn native(gpa: Allocator, path: series.Path) Allocator.Error![]const u8 {
    return std.mem.replaceOwned(u8, gpa, path.bytes, "/", std.fs.path.sep_str);
}
