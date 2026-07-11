const std = @import("std");

pub const OverlayRule = enum {
    higher_priority_wins,
    entry_tombstone_hides_lower,
};

test "overlay rules are explicit" {
    try std.testing.expectEqual(OverlayRule.higher_priority_wins, OverlayRule.higher_priority_wins);
}
