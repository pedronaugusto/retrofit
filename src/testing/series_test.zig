//! A patch read as the changes it makes: a mail as git format-patch writes one,
//! git's headers for created, deleted, renamed and copied files, and each refusal by
//! its name.

const std = @import("std");
const series = @import("../series.zig");
const testing = std.testing;

fn read(text: []const u8) !series.Patch {
    var diagnostic: series.Diagnostic = .{};
    return series.read(testing.allocator, .init(text), &diagnostic);
}

fn refused(text: []const u8, expected: series.Error, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: series.Diagnostic = .{};
    try testing.expectError(expected, series.read(arena.allocator(), .init(text), &diagnostic));
    if (std.mem.find(u8, diagnostic.message, message) == null) {
        std.debug.print("message: {s}\n", .{diagnostic.message});
        return error.TestUnexpectedResult;
    }
}

/// As git format-patch writes one: the mail, its message, a diffstat, the diff, the signature.
pub const mail =
    \\From 1111111111111111111111111111111111111111 Mon Sep 17 00:00:00 2001
    \\From: A Maintainer <m@example.org>
    \\Date: Sat, 31 Oct 2026 12:00:00 +0000
    \\Subject: [PATCH] cgltf: check the buffer view's length
    \\
    \\cgltf reads a buffer view past its buffer when the view's length is
    \\larger than the buffer (cgltf.h:1204). A new file mode or a binary
    \\change named in prose is not a header.
    \\
    \\---
    \\ lib.c | 2 +-
    \\ 1 file changed, 1 insertion(+), 1 deletion(-)
    \\
    \\diff --git a/lib.c b/lib.c
    \\index 1111111..2222222 100644
    \\--- a/lib.c
    \\+++ b/lib.c
    \\@@ -1,3 +1,3 @@ int f(void)
    \\ int f(void) {
    \\-    return 1;
    \\+    return 2;
    \\ }
    \\--
    \\2.43.0
    \\
    \\
;

test "a mail as git format-patch writes one is its diff's changes; its message and signature are not" {
    var patch = try read(mail);
    defer patch.deinit();
    try testing.expectEqual(1, patch.changes.len);
    const change = patch.changes[0];
    try testing.expectEqual(series.Change.Kind.modify, change.kind);
    try testing.expectEqualStrings("lib.c", change.from.?.bytes);
    try testing.expectEqualStrings("lib.c", change.to.?.bytes);
    try testing.expectEqual(1, change.file.hunks.len);
}

test "git's headers: a created, a deleted and an empty created file, a rename with and without hunks, a copy" {
    var patch = try read(
        \\diff --git a/new.h b/new.h
        \\new file mode 100644
        \\index 0000000..1111111
        \\--- /dev/null
        \\+++ b/new.h
        \\@@ -0,0 +1 @@
        \\+#define NEW 1
        \\diff --git a/old.h b/old.h
        \\deleted file mode 100644
        \\index 1111111..0000000
        \\--- a/old.h
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-#define OLD 1
        \\diff --git a/empty b/empty
        \\new file mode 100644
        \\index 0000000..e69de29
        \\diff --git a/a.c b/b.c
        \\similarity index 100%
        \\rename from a.c
        \\rename to b.c
        \\diff --git a/c.c b/d/c.c
        \\similarity index 80%
        \\rename from c.c
        \\rename to d/c.c
        \\index 1111111..2222222 100644
        \\--- a/c.c
        \\+++ b/d/c.c
        \\@@ -1 +1 @@
        \\-one
        \\+two
        \\diff --git a/e.c b/f.c
        \\similarity index 100%
        \\copy from e.c
        \\copy to f.c
        \\
    );
    defer patch.deinit();
    const Expected = struct { series.Change.Kind, ?[]const u8, ?[]const u8, usize };
    const expected = [_]Expected{
        .{ .create, null, "new.h", 1 },
        .{ .delete, "old.h", null, 1 },
        .{ .create, null, "empty", 0 },
        .{ .rename, "a.c", "b.c", 0 },
        .{ .rename, "c.c", "d/c.c", 1 },
        .{ .copy, "e.c", "f.c", 0 },
    };
    try testing.expectEqual(expected.len, patch.changes.len);
    for (expected, patch.changes) |want, change| {
        try testing.expectEqual(want[0], change.kind);
        if (want[1]) |from| try testing.expectEqualStrings(from, change.from.?.bytes) else try testing.expectEqual(null, change.from);
        if (want[2]) |to| try testing.expectEqualStrings(to, change.to.?.bytes) else try testing.expectEqual(null, change.to);
        try testing.expectEqual(want[3], change.file.hunks.len);
    }
}

test "a hunk line keeps its carriage return: line endings are bytes" {
    var patch = try read("--- a/w.c\r\n+++ b/w.c\r\n@@ -1 +1 @@\r\n-one\r\n+two\r\n");
    defer patch.deinit();
    const lines = patch.changes[0].file.hunks[0].lines;
    try testing.expectEqualStrings("one\r\n", lines[0].text);
    try testing.expectEqualStrings("two\r\n", lines[1].text);
}

test "binary and mode changes, paths out of the tree, quoted and mismatched names are refused by name" {
    try refused("diff --git a/x.png b/x.png\nindex 1111111..2222222 100644\nGIT binary patch\nliteral 5\nMcmZQzWMXCj0002G0RR91\n\n", error.BinaryChange, "a binary change");
    try refused("diff --git a/x.png b/x.png\nindex 1111111..2222222 100644\nBinary files a/x.png and b/x.png differ\n", error.BinaryChange, "a binary change");
    try refused("diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n", error.ModeChange, "a mode change is not applied");
    try refused("diff --git a/link b/link\nnew file mode 120000\nindex 0000000..1111111\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+target\n\\ No newline at end of file\n", error.ModeChange, "mode 120000 is no regular file's");
    try refused("--- a/../etc/passwd\n+++ b/../etc/passwd\n@@ -1 +1 @@\n-a\n+b\n", error.PathOutsideTree, "`../etc/passwd` is no path inside the tree");
    try refused("--- a/c:/x\n+++ b/c:/x\n@@ -1 +1 @@\n-a\n+b\n", error.PathOutsideTree, "no path inside the tree");
    try refused("diff --git a/x b/y\nrename from x\nrename to ../y\n", error.PathOutsideTree, "`../y` is no path inside the tree");
    try refused("--- \"a/t\\tb\"\n+++ \"b/t\\tb\"\n@@ -1 +1 @@\n-a\n+b\n", error.QuotedPath, "a quoted name");
    try refused("--- a/x\n+++ b/y\n@@ -1 +1 @@\n-a\n+b\n", error.InconsistentNames, "`---` names x and `+++` y, with no rename");
    try refused("--- x\n+++ x\n@@ -1 +1 @@\n-a\n+b\n", error.InconsistentNames, "`x` is not `a/…`");
    try refused("--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n a\n", error.MalformedHunk, "line ");
    try refused("just words\n", error.NoChange, "no file is changed");
}
