//! One patch of a series, read as the changes it makes to a tree. A patch is a
//! mail as `git format-patch` writes one (its message, then the diff), or a bare
//! `git diff`. parallax reads the unified diff and keeps each file's git header
//! lines verbatim; this reads those headers: a created, deleted, renamed or copied
//! file. A mode change and a binary change are refused by name, as is a path that
//! leaves the tree.

const std = @import("std");
const aegis = @import("aegis");
const parallax = @import("parallax");
const Allocator = std.mem.Allocator;

/// What a series reader refuses past.
pub const limits = struct {
    /// The largest patch read: a patch over an upstream is source, never this large.
    pub const patch_bytes: aegis.units.Bytes(u64) = .fromRaw(64 << 20);
    /// The most files one patch changes.
    pub const files: usize = 1 << 16;
    /// The longest path a patch names, and the most components in it.
    pub const path_bytes: usize = 4096;
    pub const path_depth: usize = 256;
};

pub const Error = error{
    OutOfMemory,
    /// The patch is larger than `limits.patch_bytes`, or changes more than `limits.files` files.
    PatchTooLarge,
    /// No file is changed: the text holds no diff.
    NoChange,
    /// A hunk's lines do not add up to its `@@` counts, or a line in it is no hunk line.
    MalformedHunk,
    /// A `GIT binary patch` or `Binary files … differ`: only text hunks are applied.
    BinaryChange,
    /// `old mode`/`new mode`, or a mode line on a created file other than a regular file's.
    ModeChange,
    /// A path that is absolute, climbs with `..`, holds a backslash, a colon, a NUL or an
    /// empty component, or is longer or deeper than `limits` allow.
    PathOutsideTree,
    /// A quoted path (`"a/x\tb"`): git quotes a name it cannot write plainly.
    QuotedPath,
    /// The names of a change disagree: `---` and `+++` name different files with no rename,
    /// or a section names no file at all.
    InconsistentNames,
};

/// Why a patch was refused, for the build to print: the message names what was read.
pub const Diagnostic = struct {
    /// The patch's 1-based line, when known.
    line: u32 = 0,
    message: []const u8 = "",
};

/// A path a patch names, let through by `inside`: relative, inside the tree, within
/// `limits`. Only `inside` makes one, so the tree is handed no path its rules refuse.
pub const Path = struct {
    bytes: []const u8,
};

/// One file's change.
pub const Change = struct {
    kind: Kind,
    /// The path read: null for a created file.
    from: ?Path,
    /// The path written: null for a deleted file.
    to: ?Path,
    /// The hunks, as parallax read them; none for a rename or copy with no change of text,
    /// or an empty created file.
    file: parallax.patch.File,

    pub const Kind = enum { modify, create, delete, rename, copy };

    /// The path a refusal names.
    pub fn path(change: Change) []const u8 {
        return (change.to orelse change.from.?).bytes; // safe: `read` gives every change a name
    }
};

/// A patch's changes. It borrows the patch's bytes.
pub const Patch = struct {
    changes: []const Change,
    parsed: parallax.patch.Patch,

    pub fn deinit(patch: *Patch) void {
        patch.parsed.deinit();
        patch.* = undefined;
    }
};

pub const Untrusted = aegis.input.Untrusted([]const u8);

const Reading = struct { gpa: Allocator, diagnostic: *Diagnostic };

/// Reads one patch's changes. The result borrows `bytes`'s text.
pub fn read(gpa: Allocator, bytes: Untrusted, diagnostic: *Diagnostic) Error!Patch {
    return bytes.parse(Reading{ .gpa = gpa, .diagnostic = diagnostic }, readChanges);
}

fn refuse(r: Reading, err: Error, comptime format: []const u8, args: anytype) Error {
    r.diagnostic.message = r.gpa.print(format, args) catch "";
    return err;
}

fn readChanges(r: Reading, text: []const u8) Error!Patch {
    if (aegis.units.Bytes(u64).fromRaw(text.len).compare(limits.patch_bytes) == .gt) return refuse(r, error.PatchTooLarge, "{d} bytes, above the {d} a patch is read to", .{ text.len, limits.patch_bytes.raw() });
    var parse_diagnostics: parallax.patch.Diagnostics = .{};
    var parsed = parallax.patch.parse(r.gpa, text, .{ .diagnostics = &parse_diagnostics }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidHunkHeader, error.HunkLengthMismatch, error.UnexpectedLine => {
            r.diagnostic.line = parse_diagnostics.line;
            return refuse(r, error.MalformedHunk, "line {d}: {s}", .{ parse_diagnostics.line, parse_diagnostics.message });
        },
    };
    errdefer parsed.deinit();
    if (parsed.files.len > limits.files) return refuse(r, error.PatchTooLarge, "{d} files, above the {d} a patch may change", .{ parsed.files.len, limits.files });
    var changes: std.ArrayList(Change) = .empty;
    const arena = parsed.arena.allocator();
    for (parsed.files) |file| {
        const change = (try changeOf(r, file)) orelse continue;
        try changes.append(arena, change);
    }
    if (changes.items.len == 0) return refuse(r, error.NoChange, "no file is changed: a patch is a diff, as git diff or git format-patch writes one", .{});
    return .{ .changes = changes.items, .parsed = parsed };
}

/// The change one of parallax's sections makes, or null for text that is no file's change
/// (a mail's signature after the last hunk).
fn changeOf(r: Reading, file: parallax.patch.File) Error!?Change {
    var git: ?[]const u8 = null;
    var created = false;
    var deleted = false;
    var renamed: [2]?Path = .{ null, null };
    var copied: [2]?Path = .{ null, null };
    for (file.header) |line| {
        if (startsWith(line, "diff --git ")) {
            git = line;
        } else if (git == null) {
            // Before a `diff --git`, a mail's message: binary or mode words there are prose.
            continue;
        } else if (startsWith(line, "GIT binary patch") or (startsWith(line, "Binary files ") and std.mem.endsWith(u8, line, " differ"))) {
            return refuse(r, error.BinaryChange, "{s}: a binary change; only text hunks are applied", .{line});
        } else if (startsWith(line, "old mode ") or startsWith(line, "new mode ")) {
            return refuse(r, error.ModeChange, "{s}: `{s}`: a mode change is not applied", .{ git.?, line });
        } else if (startsWith(line, "new file mode ")) {
            try regular(r, git.?, line["new file mode ".len..]);
            created = true;
        } else if (startsWith(line, "deleted file mode ")) {
            deleted = true;
        } else if (startsWith(line, "rename from ")) {
            renamed[0] = try inside(r, line["rename from ".len..]);
        } else if (startsWith(line, "rename to ")) {
            renamed[1] = try inside(r, line["rename to ".len..]);
        } else if (startsWith(line, "copy from ")) {
            copied[0] = try inside(r, line["copy from ".len..]);
        } else if (startsWith(line, "copy to ")) {
            copied[1] = try inside(r, line["copy to ".len..]);
        }
    }
    const old = if (file.old_name) |name| try named(r, name, "a/") else null;
    const new = if (file.new_name) |name| try named(r, name, "b/") else null;
    if (renamed[0] != null or renamed[1] != null or copied[0] != null or copied[1] != null) {
        const rename = renamed[0] != null or renamed[1] != null;
        const pair = if (rename) renamed else copied;
        const from = pair[0] orelse return refuse(r, error.InconsistentNames, "{s}: a rename or copy with no `from` line", .{git.?});
        const to = pair[1] orelse return refuse(r, error.InconsistentNames, "{s}: a rename or copy with no `to` line", .{git.?});
        if (file.old_name != null and !same(old, from)) return refuse(r, error.InconsistentNames, "{s}: `---` names {s}, not {s}", .{ git.?, if (old) |o| o.bytes else "/dev/null", from.bytes });
        if (file.new_name != null and !same(new, to)) return refuse(r, error.InconsistentNames, "{s}: `+++` names {s}, not {s}", .{ git.?, if (new) |n| n.bytes else "/dev/null", to.bytes });
        return .{ .kind = if (rename) .rename else .copy, .from = from, .to = to, .file = file };
    }
    if (file.old_name == null and file.new_name == null) {
        // No `---`: a git header alone (an empty file created or deleted), or text that is no change.
        const line = git orelse return null;
        const name = try gitName(r, line);
        if (created and !deleted) return .{ .kind = .create, .from = null, .to = name, .file = file };
        if (deleted and !created) return .{ .kind = .delete, .from = name, .to = null, .file = file };
        return refuse(r, error.InconsistentNames, "{s}: a header that changes nothing a hunk carries", .{line});
    }
    if (old == null and new == null) return refuse(r, error.InconsistentNames, "/dev/null becomes /dev/null", .{});
    if (old == null) return .{ .kind = .create, .from = null, .to = new, .file = file };
    if (new == null) return .{ .kind = .delete, .from = old, .to = null, .file = file };
    if (!same(old, new.?)) return refuse(r, error.InconsistentNames, "`---` names {s} and `+++` {s}, with no rename", .{ old.?.bytes, new.?.bytes });
    if (created or deleted) return refuse(r, error.InconsistentNames, "{s}: created or deleted, yet both names are files", .{git.?});
    return .{ .kind = .modify, .from = old, .to = new, .file = file };
}

/// A created file's mode: a regular file, executable or not; a link or a submodule is refused.
fn regular(r: Reading, git: []const u8, mode: []const u8) Error!void {
    if (std.mem.eql(u8, mode, "100644") or std.mem.eql(u8, mode, "100755")) return;
    return refuse(r, error.ModeChange, "{s}: mode {s} is no regular file's", .{ git, mode });
}

/// The path of a `---` or `+++` name: `/dev/null` is null, any other starts with `prefix`.
fn named(r: Reading, name: []const u8, prefix: []const u8) Error!?Path {
    if (std.mem.eql(u8, name, "/dev/null")) return null;
    if (name.len != 0 and name[0] == '"') return refuse(r, error.QuotedPath, "{s}: a quoted name; write the patch with `git -c core.quotePath=false format-patch`, or rename the file", .{name});
    if (!startsWith(name, prefix)) return refuse(r, error.InconsistentNames, "`{s}` is not `{s}…`: paths are read as git writes them", .{ name, prefix });
    return try inside(r, name[prefix.len..]);
}

/// The name a `diff --git a/<p> b/<p>` line gives a file whose two names are the same.
fn gitName(r: Reading, line: []const u8) Error!Path {
    const rest = line["diff --git ".len..];
    if (rest.len != 0 and rest[0] == '"') return refuse(r, error.QuotedPath, "{s}: a quoted name", .{line});
    // `a/<p> b/<p>`: both halves the same length.
    if (rest.len < "a/ b/".len or (rest.len - " ".len) % 2 != 0) return refuse(r, error.InconsistentNames, "{s}: no one name", .{line});
    const half = (rest.len - " ".len) / 2;
    const a = rest[0..half];
    const b = rest[half + 1 ..];
    if (rest[half] != ' ' or !startsWith(a, "a/") or !startsWith(b, "b/") or !std.mem.eql(u8, a[2..], b[2..]))
        return refuse(r, error.InconsistentNames, "{s}: no one name", .{line});
    return inside(r, a[2..]);
}

/// `raw` let through as a path inside the tree: the parser an untrusted path goes through.
fn inside(r: Reading, raw: []const u8) Error!Path {
    return aegis.input.Untrusted([]const u8).init(raw).parse(r, checkPath);
}

/// A path when it stays inside the tree: relative, no `.` or `..` or empty component, no
/// backslash, colon or NUL, within `limits`.
fn checkPath(r: Reading, path: []const u8) Error!Path {
    if (path.len == 0 or path.len > limits.path_bytes) return refuse(r, error.PathOutsideTree, "`{s}` is no path inside the tree", .{path});
    if (path[0] == '"') return refuse(r, error.QuotedPath, "`{s}`: a quoted name", .{path});
    var depth: usize = 0;
    var steps = std.mem.splitScalar(u8, path, '/');
    while (steps.next()) |step| {
        depth += 1;
        if (depth > limits.path_depth or step.len == 0 or std.mem.eql(u8, step, ".") or std.mem.eql(u8, step, "..") or std.mem.findAny(u8, step, "\\:\x00") != null)
            return refuse(r, error.PathOutsideTree, "`{s}` is no path inside the tree", .{path});
    }
    return .{ .bytes = path };
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, text, prefix);
}

fn same(x: ?Path, y: Path) bool {
    return if (x) |v| std.mem.eql(u8, v.bytes, y.bytes) else false;
}
