//! retrofit's input seam: the patches of a series and the upstream's files a
//! patch changes, each read whole under its limit. Everything else reads the
//! bytes these hand it.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = aegis.own.ReadFileError;

/// The patch at `path` (absolute, or from the working directory), at most
/// `max` bytes, owned by the caller.
pub fn patch(io: Io, gpa: Allocator, path: []const u8, max: aegis.units.Bytes(u64)) Error![]u8 {
    return aegis.own.readFile(io, Io.Dir.cwd(), path, gpa, max);
}

/// The file at `path` in the tree `dir`, at most `max` bytes, owned by the
/// caller.
pub fn file(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, max: aegis.units.Bytes(u64)) Error![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, max);
}
