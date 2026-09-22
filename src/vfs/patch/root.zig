pub const overlay = @import("overlay.zig");
pub const diff_pack_reader = @import("diff_pack_reader.zig");
pub const chain = @import("chain.zig");
pub const coalesce = @import("coalesce.zig");
pub const old_view = @import("old_view.zig");
pub const shard_writer = @import("shard_writer.zig");
pub const patch_session = @import("patch_session.zig");

pub const PatchOptions = patch_session.PatchOptions;
pub const VerifyAfter = patch_session.VerifyAfter;
pub const Report = patch_session.Report;
pub const run = patch_session.run;

test {
    _ = overlay;
    _ = diff_pack_reader;
    _ = chain;
    _ = coalesce;
    _ = old_view;
    _ = shard_writer;
    _ = patch_session;
    _ = @import("patch_test.zig");
}
