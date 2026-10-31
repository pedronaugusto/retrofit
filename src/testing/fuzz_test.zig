//! The series reader fuzzed: patches built from the pieces of git's patch syntax,
//! read without a crash, and every change read names paths inside the tree.

const std = @import("std");
const shakedown = @import("shakedown");
const series = @import("../series.zig");
const gen = shakedown.gen;

const pieces = [_][]const u8{
    "diff --git a/x.c b/x.c\n", "diff --git a/a b/b\n",       "diff --git \"a/q\" \"b/q\"\n",   "index 1111111..2222222 100644\n",
    "--- a/x.c\n",              "+++ b/x.c\n",                "--- /dev/null\n",                "+++ /dev/null\n",
    "--- a/../x\n",             "+++ b/c:/x\n",               "@@ -1,2 +1,2 @@\n",              "@@ -0,0 +1 @@\n",
    "@@ -1 +0,0 @@\n",          "@@ -4294967295 +1 @@\n",     " ctx\n",                         "-old\n",
    "+new\n",                   " ctx\r\n",                   "\\ No newline at end of file\n", "new file mode 100644\n",
    "new file mode 120000\n",   "deleted file mode 100644\n", "old mode 100644\n",              "new mode 100755\n",
    "rename from a\n",          "rename to b\n",              "rename to ../b\n",               "copy from a\n",
    "copy to b\n",              "similarity index 90%\n",     "GIT binary patch\n",             "Binary files a/x and b/x differ\n",
    "Subject: [PATCH] x\n",     "---\n",                      "-- \n",                          "2.43.0\n",
    "\n",                       "x",                          "\r\n",                           "\x00",
};

fn readOne(_: void, case: *shakedown.Case) !void {
    const fragments = try gen.slice(case.source, []const u8, struct {
        fn draw(source: *shakedown.Source) []const u8 {
            return gen.oneOf(source, []const u8, &pieces);
        }
    }.draw, case.gpa, .{ .average = 12, .max_len = 96 });
    const text = try std.mem.concat(case.gpa, u8, fragments);
    defer case.gpa.free(text);
    var diagnostic: series.Diagnostic = .{};
    var patch = series.read(case.gpa, .init(text), &diagnostic) catch |err| {
        if (diagnostic.message.len != 0) case.gpa.free(diagnostic.message);
        switch (err) {
            error.OutOfMemory => return err,
            else => return,
        }
    };
    defer patch.deinit();
    try std.testing.expect(patch.changes.len != 0);
    for (patch.changes) |change| {
        for ([_]?series.Path{ change.from, change.to }) |path| {
            const p = (path orelse continue).bytes;
            try std.testing.expect(p.len != 0 and p[0] != '/' and std.mem.find(u8, p, "..") == null and std.mem.findAny(u8, p, "\\:\x00") == null);
        }
        try std.testing.expect(change.from != null or change.to != null);
    }
}

test "fuzz: a patch is read whole or refused by name, its paths inside the tree" {
    try shakedown.check(std.testing.allocator, {}, readOne, .{ .seed = 0x72657472, .cases = 3000 });
}
