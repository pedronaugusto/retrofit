//! The README's promises held over generated series: a series of changes
//! (files modified, created and deleted, their lines ending in LF or CRLF)
//! makes exactly the tree it says, every other file the upstream's; and one
//! byte of the upstream changed under a hunk's context or removed lines
//! refuses the hunk, never applying it anyway.
const std = @import("std");
const shakedown = @import("shakedown");
const tree = @import("../tree.zig");

const testing = std.testing;
const gen = shakedown.gen;

const words = [_][]const u8{ "a", "bb", "c c", "", "int f(void);" };

/// A file's lines, each with its line ending.
const Lines = struct {
    items: [8][]const u8 = undefined,
    len: usize = 0,
    fn slice(l: *const Lines) []const []const u8 {
        return l.items[0..l.len];
    }
};

fn drawLines(s: *shakedown.Source, crlf: bool, at_least: usize, store: *std.heap.ArenaAllocator) !Lines {
    var l: Lines = .{};
    l.len = gen.intRange(s, usize, at_least, 6);
    for (l.items[0..l.len]) |*line| line.* = try std.mem.concat(store.allocator(), u8, &.{ words[gen.intRange(s, usize, 0, words.len - 1)], if (crlf) "\r\n" else "\n" });
    return l;
}

fn joined(a: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    return std.mem.concat(a, u8, lines);
}

/// One hunk turning `old` into `new`: their common first and last lines as
/// context, the rest removed and added.
fn hunk(w: *std.Io.Writer, old: []const []const u8, new: []const []const u8) !void {
    var prefix: usize = 0;
    while (prefix < old.len and prefix < new.len and std.mem.eql(u8, old[prefix], new[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < old.len - prefix and suffix < new.len - prefix and std.mem.eql(u8, old[old.len - 1 - suffix], new[new.len - 1 - suffix])) suffix += 1;
    try w.print("@@ -{d},{d} +{d},{d} @@\n", .{ @intFromBool(old.len != 0), old.len, @intFromBool(new.len != 0), new.len });
    for (old[0..prefix]) |line| try w.print(" {s}", .{line});
    for (old[prefix .. old.len - suffix]) |line| try w.print("-{s}", .{line});
    for (new[prefix .. new.len - suffix]) |line| try w.print("+{s}", .{line});
    for (old[old.len - suffix ..]) |line| try w.print(" {s}", .{line});
}

const Change = enum { keep, modify, delete };

test "a series makes exactly the tree it says; one byte changed under a hunk refuses it" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            var store: std.heap.ArenaAllocator = .init(testing.allocator);
            defer store.deinit();
            const a = store.allocator();
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = testing.io;
            try tmp.dir.createDirPath(io, "upstream");
            var patch: std.Io.Writer.Allocating = .init(a);

            const files = gen.intRange(s, usize, 1, 4);
            var olds: [4]Lines = undefined;
            var news: [4]Lines = undefined;
            var changes: [4]Change = undefined;
            // A file whose hunk covers a line the upstream changes, if any:
            // the series must then be refused.
            var tampered = false;
            for (0..files) |k| {
                const crlf = gen.boolean(s);
                olds[k] = try drawLines(s, crlf, 0, &store);
                const name = try std.mem.print(try a.alloc(u8, 16), "f{d}.txt", .{k});
                changes[k] = switch (gen.intRange(s, u8, 0, 2)) {
                    0 => .keep,
                    1 => .modify,
                    else => if (olds[k].len == 0) .keep else .delete,
                };
                var upstream_lines = olds[k];
                switch (changes[k]) {
                    .keep => {},
                    .modify => modify: {
                        news[k] = try drawLines(s, crlf, 0, &store);
                        // Empty to empty is no hunk at all: the file is kept.
                        if (olds[k].len == 0 and news[k].len == 0) {
                            changes[k] = .keep;
                            break :modify;
                        }
                        try patch.writer.print("diff --git a/{s} b/{s}\n--- a/{s}\n+++ b/{s}\n", .{ name, name, name, name });
                        try hunk(&patch.writer, olds[k].slice(), news[k].slice());
                        if (olds[k].len != 0 and gen.intRange(s, u8, 0, 4) == 0) {
                            // One byte of one line the hunk covers, changed.
                            const i = gen.intRange(s, usize, 0, olds[k].len - 1);
                            upstream_lines.items[i] = try std.mem.concat(a, u8, &.{ "x", olds[k].items[i] });
                            tampered = true;
                        }
                    },
                    .delete => {
                        try patch.writer.print("diff --git a/{s} b/{s}\ndeleted file mode 100644\n--- a/{s}\n+++ /dev/null\n", .{ name, name, name });
                        try hunk(&patch.writer, olds[k].slice(), &.{});
                    },
                }
                const path = try std.mem.concat(a, u8, &.{ "upstream/", name });
                try tmp.dir.writeFile(io, .{ .sub_path = path, .data = try joined(a, upstream_lines.slice()) });
            }
            // Now and then a file the series creates.
            var created: ?Lines = null;
            if (gen.boolean(s)) {
                created = try drawLines(s, gen.boolean(s), 1, &store);
                try patch.writer.writeAll("diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n");
                try hunk(&patch.writer, &.{}, created.?.slice());
            }
            if (patch.written().len == 0) return;
            try tmp.dir.writeFile(io, .{ .sub_path = "0001.patch", .data = patch.written() });

            const root = try tmp.dir.realPathFileAlloc(io, ".", a);
            const patch_path = try std.fs.path.join(a, &.{ root, "0001.patch" });
            var upstream = try tmp.dir.openDir(io, "upstream", .{ .iterate = true });
            defer upstream.close(io);
            var out = try tmp.dir.createDirPathOpen(io, "out", .{});
            defer out.close(io);
            var diagnostic: tree.Diagnostic = .{};
            const made = tree.make(io, a, upstream, out, &.{patch_path}, &diagnostic);
            if (tampered) {
                try testing.expectError(error.HunkFailed, made);
                return;
            }
            made catch |err| {
                std.debug.print("{s}\n{s}\n", .{ diagnostic.message, patch.written() });
                return err;
            };
            for (0..files) |k| {
                const name = try std.mem.print(try a.alloc(u8, 16), "f{d}.txt", .{k});
                switch (changes[k]) {
                    .delete => try testing.expectError(error.FileNotFound, out.access(io, name, .{})),
                    .keep, .modify => {
                        const want = try joined(a, if (changes[k] == .keep) olds[k].slice() else news[k].slice());
                        const got = try out.readFileAlloc(io, name, a, .limited(1 << 16));
                        try testing.expectEqualStrings(want, got);
                    },
                }
            }
            if (created) |c| try testing.expectEqualStrings(try joined(a, c.slice()), try out.readFileAlloc(io, "new.txt", a, .limited(1 << 16)));
        }
    }.one, .{ .cases = 400 });
}
