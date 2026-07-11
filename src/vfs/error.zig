const std = @import("std");

pub const Status = enum(c_int) {
    ok = 0,
    not_found = 1,
    invalid_argument = 2,
    io_error = 3,
    corruption = 4,
    checksum_mismatch = 5,
    unsupported_version = 6,
    unsupported_feature = 7,
    permission_denied = 8,
    key_collision = 9,
    db_error = 10,
    busy = 11,
    internal_error = 100,
};

pub fn fromError(err: anyerror) Status {
    return switch (err) {
        error.NotFound, error.FileNotFound => .not_found,
        error.InvalidArgument => .invalid_argument,
        error.AccessDenied => .permission_denied,
        error.UnsupportedVersion => .unsupported_version,
        error.Unsupported, error.UnsupportedFeature => .unsupported_feature,
        error.Corruption => .corruption,
        error.ChecksumMismatch => .checksum_mismatch,
        error.KeyCollision => .key_collision,
        error.Busy => .busy,
        error.DbError => .db_error,
        error.OutOfMemory, error.NoSpace => .internal_error,
        else => .io_error,
    };
}

pub fn code(status: Status) c_int {
    return @intFromEnum(status);
}

test "vfs status values are stable" {
    try std.testing.expectEqual(@as(c_int, 0), code(.ok));
    try std.testing.expectEqual(@as(c_int, 7), code(.unsupported_feature));
    try std.testing.expectEqual(@as(c_int, 100), code(.internal_error));
}
