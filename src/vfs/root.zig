pub const abi = @import("abi.zig");
pub const errors = @import("error.zig");
pub const handle_registry = @import("handle_registry.zig");
pub const hash = @import("hash.zig");
pub const object_key = @import("object_key.zig");
pub const path = @import("path.zig");

pub const format = struct {
    pub const common = @import("format/common.zig");
    pub const pack_manifest = @import("format/pack_manifest.zig");
    pub const path_index = @import("format/path_index.zig");
    pub const directory_manifest = @import("format/directory_manifest.zig");
    pub const file_manifest = @import("format/file_manifest.zig");
    pub const page_value = @import("format/page_value.zig");
    pub const tombstone = @import("format/tombstone.zig");
    pub const patch_manifest = @import("format/patch_manifest.zig");
    pub const volume_manifest = @import("format/volume_manifest.zig");
    pub const volume_transaction = @import("format/volume_transaction.zig");
};

pub const compress = struct {
    pub const compressor = @import("compress/compressor.zig");
    pub const registry = @import("compress/registry.zig");
    pub const none = @import("compress/none.zig");
    pub const lz4 = @import("compress/lz4.zig");
    pub const zstd = @import("compress/zstd.zig");
};

pub const pack = struct {
    pub const pack_writer = @import("pack/pack_writer.zig");
    pub const pack_reader = @import("pack/pack_reader.zig");
};

pub const tools = struct {
    pub const pack_tools = @import("tools/pack_tools.zig");
};

pub const build = struct {
    pub const build_cfg = @import("build/build_cfg.zig");
    pub const build_plan = @import("build/build_plan.zig");
    pub const build_cache = @import("build/build_cache.zig");
    pub const pack_builder = @import("build/pack_builder.zig");
};

pub const volume = struct {
    pub const volume = @import("volume/volume.zig");
    pub const mount_table = @import("volume/mount_table.zig");
    pub const overlay_resolver = @import("volume/overlay_resolver.zig");
    pub const entry_resolver = @import("volume/entry_resolver.zig");
    pub const path_resolver = @import("volume/path_resolver.zig");
    pub const staging = @import("volume/staging.zig");
};

pub const mutation = @import("mutation/root.zig");

pub const io = struct {
    pub const file_handle = @import("io/file_handle.zig");
    pub const page_cache = @import("io/page_cache.zig");
};

comptime {
    _ = abi.vfs_open_volume;
    _ = abi.vfs_close_volume;
    _ = abi.vfs_mount_pack;
    _ = abi.vfs_open_path;
    _ = abi.vfs_open_entry;
    _ = abi.vfs_stat_path;
    _ = abi.vfs_stat_entry;
    _ = abi.vfs_read_at;
    _ = abi.vfs_close_file;
    _ = abi.vfs_last_status;
    _ = abi.vfs_last_error_message;
}

test {
    _ = abi;
    _ = errors;
    _ = handle_registry;
    _ = hash;
    _ = object_key;
    _ = path;
    _ = format.common;
    _ = format.pack_manifest;
    _ = format.path_index;
    _ = format.directory_manifest;
    _ = format.file_manifest;
    _ = format.page_value;
    _ = format.tombstone;
    _ = format.patch_manifest;
    _ = format.volume_manifest;
    _ = format.volume_transaction;
    _ = compress.compressor;
    _ = compress.registry;
    _ = compress.none;
    _ = compress.lz4;
    _ = compress.zstd;
    _ = pack.pack_writer;
    _ = pack.pack_reader;
    _ = tools.pack_tools;
    _ = build.build_cfg;
    _ = build.build_plan;
    _ = build.build_cache;
    _ = build.pack_builder;
    _ = volume.volume;
    _ = volume.mount_table;
    _ = volume.overlay_resolver;
    _ = volume.entry_resolver;
    _ = volume.path_resolver;
    _ = volume.staging;
    _ = mutation;
    _ = io.file_handle;
    _ = io.page_cache;
    const c = @cImport({
        @cInclude("vfs.h");
    });
    try @import("std").testing.expectEqual(@as(c_int, 0), c.VFS_OK);
}
