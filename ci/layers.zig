//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "a patch read", .patterns = &.{"src/series.zig"} },
    .{ .name = "the patched tree", .patterns = &.{"src/tree.zig"} },
    .{ .name = "the program", .patterns = &.{"src/main.zig"} },
};

pub const entries: []const []const u8 = &.{"src/main.zig"};

pub const modules: []const gantry.NamedModule = &.{};

/// Durable writes go through airlock; the patched tree is the build cache's, which Zig's
/// own cache makes whole, so retrofit makes none.
pub const owned: []const gantry.rules.TokenRule = &durability;

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{ "std", "aegis", "parallax", "shakedown", "builtin" } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = [_][]const u8{
    "src/series.zig",
    "src/tree.zig",
    "src/main.zig",
    "src/tests.zig",
};

const durability = [_]gantry.rules.TokenRule{.{
    .name = "durability belongs to airlock",
    .sequences = &.{
        &.{ ".", "sync", "(" },
        &.{ ".", "syncFile", "(" },
        &.{ ".", "syncDir", "(" },
        &.{ "createFileAtomic", "(" },
        &.{ "fsync", "(" },
        &.{ "fdatasync", "(" },
        &.{ "FlushFileBuffers", "(" },
    },
}};
