//! `retrofit <upstream> <out> <patch>...`: the program `patched` runs on the build's
//! host. It copies the upstream's tree into `out` and applies each patch, in the order
//! given, exactly; a patch that does not apply fails the build, naming the patch, the
//! file and the hunk.

const std = @import("std");
const tree = @import("tree.zig");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) {
        try Io.File.stderr().writeStreamingAll(io, "usage: retrofit <upstream> <out> <patch>...\n");
        return 2;
    }
    var upstream = try Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer upstream.close(io);
    try Io.Dir.cwd().deleteTree(io, args[2]);
    var out = try Io.Dir.cwd().createDirPathOpen(io, args[2], .{});
    defer out.close(io);
    var diagnostic: tree.Diagnostic = .{};
    tree.make(io, gpa, upstream, out, args[3..], &diagnostic) catch |err| {
        const message = if (diagnostic.message.len == 0) try gpa.print("error: retrofit: {t}\n", .{err}) else try gpa.print("error: retrofit: {s} ({t})\n", .{ diagnostic.message, err });
        try Io.File.stderr().writeStreamingAll(io, message);
        return 1;
    };
    return 0;
}
