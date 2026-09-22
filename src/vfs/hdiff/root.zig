pub const sais = @import("sais.zig");
pub const varint = @import("varint.zig");
pub const rle = @import("rle.zig");
pub const cover = @import("cover.zig");
pub const diff = @import("diff.zig");

pub const DiffOptions = diff.DiffOptions;
pub const Header = diff.Header;
pub const HEADER_SIZE = diff.HEADER_SIZE;
pub const createDiff = diff.diff;
pub const patch = diff.patch;
pub const patchAlloc = diff.patchAlloc;
pub const decodeHeader = diff.decodeHeader;

test {
    _ = sais;
    _ = varint;
    _ = rle;
    _ = cover;
    _ = diff;
}
