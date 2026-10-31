const std = @import("std");

/// What a project that depends on retrofit builds: the `retrofit` program, which
/// `patched` runs on the build's host. A package's own build calls `patched`; the
/// tests and the gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    b.installArtifact(b.addExecutable(.{ .name = "retrofit", .root_module = program(b, b, target, optimize) }));
}

/// `upstream`'s tree with a package's own patches applied: every file in the directory
/// `patches`, each a `.patch` as `git format-patch` writes it, in the byte order of
/// their names (`0001-…`, `0002-…`), each hunk exactly where it says, or the build
/// fails naming the patch, the file and the hunk. The upstream's hash pin proves the
/// upstream, and the tree this gives is the one the package compiles: upstream plus
/// exactly those patches. `b` is the build of the package that names retrofit a
/// dependency; the patches directory must exist when that build is configured.
pub fn patched(b: *std.Build, upstream: std.Build.LazyPath, patches: std.Build.LazyPath) std.Build.LazyPath {
    const self = b.dependencyFromBuildZig(@This(), .{});
    const exe = b.addExecutable(.{ .name = "retrofit", .root_module = program(b, self.builder, b.graph.host, .ReleaseSafe) });
    const run = b.addRunArtifact(exe);
    run.addDirectoryArg2(upstream, .{});
    const tree = run.addOutputDirectoryArg2("patched", .{});
    // Each patch is a file argument, so Zig's cache reruns the step when one changes.
    const names = list(b, patches) catch |err| {
        run.step.dependOn(&b.addFail(b.fmt("retrofit: the patches directory could not be read when the build was configured: {t}", .{err})).step);
        return tree;
    };
    for (names) |name| {
        if (!std.mem.endsWith(u8, name, ".patch")) {
            run.step.dependOn(&b.addFail(b.fmt("retrofit: {s} in the patches directory is no .patch: it holds the series alone, every file applied", .{name})).step);
            continue;
        }
        run.addFileArg(patches.path(b, name));
    }
    return tree;
}

/// The program from `package`'s sources, built in `b`, with aegis and parallax.
fn program(b: *std.Build, package: *std.Build, target: std.Build.ResolvedTarget, optimize: ?std.lang.Optimize) *std.Build.Module {
    return b.createModule(.{ .root_source_file = package.path("src/main.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "aegis", .module = package.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
        .{ .name = "parallax", .module = package.dependency("parallax", .{ .target = target, .optimize = optimize }).module("parallax") },
    } });
}

/// The names in the directory `patches`, in byte order. It is read as the build is
/// configured, so it is a directory of a package's sources, not a generated one.
fn list(b: *std.Build, patches: std.Build.LazyPath) ![]const []const u8 {
    const io = b.graph.io;
    var dir = switch (patches) {
        .src_path => |source| try source.owner.root.openDir(io, source.sub_path, .{ .iterate = true }),
        .dependency => |found| try found.dependency.builder.root.openDir(io, found.sub_path, .{ .iterate = true }),
        .cwd_relative => |path| try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }),
        .generated, .relative => return error.NotSourceDirectory,
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| try names.append(b.allocator, b.graph.dupeString(entry.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    return names.items;
}

/// retrofit's development: its tests, a consumer's build through `patched`, and the
/// gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("retrofit", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const tests = b.addTest(.{
        .name = "retrofit-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{ .root_source_file = p.path("src/tests.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
            .{ .name = "parallax", .module = p.dependency("parallax", .{ .target = target, .optimize = optimize }).module("parallax") },
            .{ .name = "shakedown", .module = b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown") },
        } }),
    });
    const test_step = b.step("test", "Run the tests and a consumer's build");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const check = b.step("check", "Compile the tests and the program without running them");
    check.dependOn(&tests.step);
    check.dependOn(&package.artifact("retrofit").step);
    // A consumer is built by a Zig of its own, with caches of its own, as a package that
    // depends on retrofit is: its patches applied and the patched upstream run, then a
    // stale patch refused.
    for ([_]struct { patches: []const u8, code: u8, stderr: ?[]const u8 }{
        .{ .patches = "patches", .code = 0, .stderr = null },
        .{ .patches = "refused", .code = 1, .stderr = "retrofit: 0001-stale.patch: lib.c: hunk 1 `@@ -1,3 +1,3 @@` does not apply at line 1: line 2 is `    return 1;`, the patch expects `    return 0;`" },
    }) |case| {
        const consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "run" });
        consumer.setCwd(p.path("test/consumer"));
        consumer.addArg(b.fmt("-Dpatches={s}", .{case.patches}));
        consumer.addArg("--cache-dir");
        _ = consumer.addOutputDirectoryArg2("cache", .{});
        consumer.addArg("--prefix");
        _ = consumer.addOutputDirectoryArg2("prefix", .{});
        consumer.expectExitCode(case.code);
        if (case.stderr) |text| consumer.addCheck(.{ .expect_stderr_match = text });
        for ([_][]const u8{ "test/consumer/build.zig", "test/consumer/build.zig.zon", "test/consumer/main.zig", "test/consumer/upstream/lib.c", "test/consumer/patches/0001-return-two.patch", "test/consumer/patches/0002-add-g.patch", "test/consumer/refused/0001-stale.patch", "build.zig", "src/main.zig", "src/series.zig", "src/tree.zig" }) |input|
            consumer.addFileInput(p.path(input));
        test_step.dependOn(&consumer.step);
    }
    tools.preflight.addCi(b, p, .{ .tests = test_step });
    b.getInstallStep().dependOn(&tests.step);
}
