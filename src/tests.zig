//! Every test of retrofit's sources: the series reader, the tree and the fuzz target.

test {
    _ = @import("testing/series_test.zig");
    _ = @import("testing/tree_test.zig");
    _ = @import("testing/fuzz_test.zig");
}
