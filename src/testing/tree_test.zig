//! The patched tree: the upstream copied whole, each patch applied exactly, byte
//! for byte, and every refusal naming the patch, the file and the hunk.

const std = @import("std");
const shakedown = @import("shakedown");
const tree = @import("../tree.zig");
const testing = std.testing;
const Io = std.Io;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,

    fn init() !Fixture {
        var f: Fixture = .{ .arena = .init(testing.allocator), .tmp = testing.tmpDir(.{}), .root = undefined };
        f.root = try f.tmp.dir.realPathFileAlloc(testing.io, ".", f.arena.allocator());
        try f.tmp.dir.createDirPath(testing.io, "upstream");
        try f.tmp.dir.createDirPath(testing.io, "patches");
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn write(f: *Fixture, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try f.tmp.dir.createDirPath(testing.io, parent);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn read(f: *Fixture, path: []const u8) ![]const u8 {
        return f.tmp.dir.readFileAlloc(testing.io, path, f.arena.allocator(), .limited(1 << 20));
    }

    /// Makes `out` from the upstream and the patches named, in that order.
    fn make(f: *Fixture, io: Io, names: []const []const u8, diagnostic: *tree.Diagnostic) !void {
        const a = f.arena.allocator();
        var paths: std.ArrayList([]const u8) = .empty;
        for (names) |name| try paths.append(a, try std.fs.path.join(a, &.{ f.root, "patches", name }));
        try f.tmp.dir.deleteTree(testing.io, "out");
        var upstream = try f.tmp.dir.openDir(testing.io, "upstream", .{ .iterate = true });
        defer upstream.close(testing.io);
        var out = try f.tmp.dir.createDirPathOpen(testing.io, "out", .{});
        defer out.close(testing.io);
        try tree.make(io, a, upstream, out, paths.items, diagnostic);
    }

    fn refused(f: *Fixture, names: []const []const u8, expected: anyerror, message: []const u8) !void {
        var diagnostic: tree.Diagnostic = .{};
        try testing.expectError(expected, f.make(testing.io, names, &diagnostic));
        if (!std.mem.eql(u8, diagnostic.message, message)) {
            std.debug.print("message: {s}\n", .{diagnostic.message});
            return error.TestUnexpectedResult;
        }
    }
};

test "the upstream is copied whole and the series applied in order, each patch over the one before" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.write("upstream/lib.c", "int f(void) {\n    return 1;\n}\n");
    try f.write("upstream/include/lib.h", "int f(void);\n");
    try f.write("patches/0001-two.patch", "diff --git a/lib.c b/lib.c\n--- a/lib.c\n+++ b/lib.c\n@@ -1,3 +1,3 @@\n int f(void) {\n-    return 1;\n+    return 2;\n }\n");
    try f.write("patches/0002-g.patch", "diff --git a/lib.c b/lib.c\n--- a/lib.c\n+++ b/lib.c\n@@ -1,3 +1,4 @@\n int f(void) {\n     return 2;\n }\n+int g(void);\n");
    var diagnostic: tree.Diagnostic = .{};
    try f.make(testing.io, &.{ "0001-two.patch", "0002-g.patch" }, &diagnostic);
    try testing.expectEqualStrings("int f(void) {\n    return 2;\n}\nint g(void);\n", try f.read("out/lib.c"));
    try testing.expectEqualStrings("int f(void);\n", try f.read("out/include/lib.h"));
    // The upstream itself is untouched.
    try testing.expectEqualStrings("int f(void) {\n    return 1;\n}\n", try f.read("upstream/lib.c"));
}

test "a CRLF upstream stays CRLF: the patch's carriage returns match and are written as they are" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.write("upstream/w.c", "one\r\ntwo\r\nthree\r\n");
    try f.write("patches/0001.patch", "--- a/w.c\n+++ b/w.c\n@@ -1,3 +1,3 @@\n one\r\n-two\r\n+TWO\r\n three\r\n");
    var diagnostic: tree.Diagnostic = .{};
    try f.make(testing.io, &.{"0001.patch"}, &diagnostic);
    try testing.expectEqualStrings("one\r\nTWO\r\nthree\r\n", try f.read("out/w.c"));
    // The same patch with its carriage returns translated away, as a text checkout makes it.
    try f.write("patches/0002.patch", "--- a/w.c\n+++ b/w.c\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n");
    try f.refused(&.{"0002.patch"}, error.HunkFailed, "0002.patch: w.c: hunk 1 `@@ -1,3 +1,3 @@` does not apply at line 1: line 1 is `one\\r`, the patch expects `one` (their line endings differ: keep the patch as git wrote it, `*.patch -text` in .gitattributes)");
}

test "a hunk applies only where it says: moved lines and changed context are refused, never fuzzed or offset" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.write("upstream/n.txt", "zero\none\ntwo\nthree\n");
    // The lines are one further down: GNU patch would apply it at an offset of 1.
    try f.write("patches/moved.patch", "--- a/n.txt\n+++ b/n.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n");
    try f.refused(&.{"moved.patch"}, error.HunkFailed, "moved.patch: n.txt: hunk 1 `@@ -1,3 +1,3 @@` does not apply at line 1: line 1 is `zero`, the patch expects `one`");
    // A context line upstream changed: GNU patch would apply it with a fuzz of 1.
    try f.write("patches/stale.patch", "--- a/n.txt\n+++ b/n.txt\n@@ -2,3 +2,3 @@\n one\n-two\n+TWO\n 3\n");
    try f.refused(&.{"stale.patch"}, error.HunkFailed, "stale.patch: n.txt: hunk 1 `@@ -2,3 +2,3 @@` does not apply at line 2: line 4 is `three`, the patch expects `3`");
}

test "files are created, deleted, renamed and copied; a created file the tree holds, a missing one and a partial deletion are refused" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.write("upstream/a.c", "a\n");
    try f.write("upstream/b.c", "b\n");
    try f.write("upstream/gone.c", "gone\n");
    try f.write("patches/0001.patch",
        \\diff --git a/new/n.h b/new/n.h
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new/n.h
        \\@@ -0,0 +1 @@
        \\+#define N 1
        \\diff --git a/gone.c b/gone.c
        \\deleted file mode 100644
        \\--- a/gone.c
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-gone
        \\diff --git a/a.c b/moved/a.c
        \\similarity index 100%
        \\rename from a.c
        \\rename to moved/a.c
        \\diff --git a/b.c b/c.c
        \\similarity index 50%
        \\copy from b.c
        \\copy to c.c
        \\--- a/b.c
        \\+++ b/c.c
        \\@@ -1 +1 @@
        \\-b
        \\+c
        \\
    );
    var diagnostic: tree.Diagnostic = .{};
    try f.make(testing.io, &.{"0001.patch"}, &diagnostic);
    try testing.expectEqualStrings("#define N 1\n", try f.read("out/new/n.h"));
    try testing.expectEqualStrings("a\n", try f.read("out/moved/a.c"));
    try testing.expectEqualStrings("b\n", try f.read("out/b.c"));
    try testing.expectEqualStrings("c\n", try f.read("out/c.c"));
    try testing.expectError(error.FileNotFound, f.read("out/gone.c"));
    try testing.expectError(error.FileNotFound, f.read("out/a.c"));

    try f.write("patches/exists.patch", "--- /dev/null\n+++ b/a.c\n@@ -0,0 +1 @@\n+again\n");
    try f.refused(&.{"exists.patch"}, error.FileExists, "exists.patch: a.c is in the tree already, and the patch makes it");
    try f.write("patches/missing.patch", "--- a/nowhere.c\n+++ b/nowhere.c\n@@ -1 +1 @@\n-a\n+b\n");
    try f.refused(&.{"missing.patch"}, error.MissingFile, "missing.patch: nowhere.c is not in the tree");
    try f.write("patches/binary.patch", "diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n");
    try f.refused(&.{"binary.patch"}, error.BinaryChange, "binary.patch: Binary files a/x.png and b/x.png differ: a binary change; only text hunks are applied");
}

test "a fault while the tree is copied or written is returned, never a tree that is not the upstream's" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.write("upstream/src/lib.c", "int f(void) {\n    return 1;\n}\n");
    try f.write("patches/0001.patch", "--- a/src/lib.c\n+++ b/src/lib.c\n@@ -1,3 +1,3 @@\n int f(void) {\n-    return 1;\n+    return 2;\n }\n");
    const faults = [_]std.meta.Elem(@FieldType(shakedown.FaultIo.Options, "plan")){
        .{ .at = .{ .nth = .{ .call = .dirOpenFile, .n = 1 } }, .fault = .{ .fail = error.AccessDenied } },
        .{ .at = .{ .nth = .{ .call = .dirCreateFile, .n = 1 } }, .fault = .{ .fail = error.NoSpaceLeft } },
        .{ .at = .{ .nth = .{ .call = .fileWriteFileStreaming, .n = 1 } }, .fault = .{ .fail = error.NoSpaceLeft } },
        .{ .at = .{ .nth = .{ .call = .fileReadPositional, .n = 1 } }, .fault = .{ .fail = error.InputOutput } },
    };
    for (faults) |step| {
        const fio = try shakedown.FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{step} });
        defer fio.deinit();
        var diagnostic: tree.Diagnostic = .{};
        if (f.make(fio.io(), &.{"0001.patch"}, &diagnostic)) |_| {
            // A fault the run never reached leaves the tree whole and patched.
            try testing.expectEqual(0, fio.fired().len);
            try testing.expectEqualStrings("int f(void) {\n    return 2;\n}\n", try f.read("out/src/lib.c"));
        } else |err| {
            try testing.expect(fio.fired().len != 0);
            try testing.expect(err != error.HunkFailed);
        }
    }
}
