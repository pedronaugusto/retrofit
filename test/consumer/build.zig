const std = @import("std");
const retrofit = @import("retrofit");

/// A package that builds an upstream with no manifest as its patches leave it.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const patches = b.option([]const u8, "patches", "The directory of patches") orelse "patches";
    const tree = retrofit.patched(b, b.dependency("upstream", .{}).path(""), b.path(patches));
    const module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .link_libc = true });
    module.addCSourceFile(.{ .file = tree.path(b, "lib.c") });
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = module });
    const run = b.addRunArtifact(exe);
    run.expectExitCode(0);
    b.step("run", "Run the patched upstream").dependOn(&run.step);
}
