//! Every test of retrofit's sources: the series reader, the tree, the fuzz target and the
//! README's promises.

test {
    _ = @import("testing/series_test.zig");
    _ = @import("testing/tree_test.zig");
    _ = @import("testing/fuzz_test.zig");
    _ = @import("testing/contract_test.zig");
}
