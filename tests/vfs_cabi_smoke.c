#include "vfs.h"

#include <stdint.h>
#include <string.h>

/*
 * C ABI is read/mount plus polling-style patch. Pack creation and diffing are
 * done by the build step (`vfs put-file`, `vfs diff-pack`) before this smoke
 * runs; see also tests/vfs_pack_roundtrip.zig.
 *
 *   argv[1] = v1 pack (patched in place by this smoke)
 *   argv[2] = DiffPack v1 -> v2
 */
static const char k_payload[] = "hello-vfs-cabi";
static const char k_payload_v2[] = "hello-vfs-cabi-v2-patched";
static const char k_vpath[] = "/textures/a.bin";
static const uint64_t k_entry = 1001;

static int read_all(vfs_volume_t volume, unsigned char* bytes, uint64_t cap, uint64_t* out_n) {
    vfs_file_t file = 0;
    int rc = vfs_open_path(volume, k_vpath, 0, &file);
    if (rc != VFS_OK || file == 0) return rc == VFS_OK ? VFS_INTERNAL_ERROR : rc;
    *out_n = 0;
    rc = vfs_read_at(file, 0, bytes, cap, out_n);
    if (vfs_close_file(file) != VFS_OK) return VFS_INTERNAL_ERROR;
    return rc;
}

int main(int argc, char** argv) {
    if (argc != 3) return 2;

    const char* pack_path = argv[1];
    const char* diff_path = argv[2];
    vfs_volume_t volume = 0;
    vfs_file_t file = 0;
    vfs_file_t file_by_entry = 0;
    unsigned char bytes[64];
    uint64_t n = 0;
    int rc;

    if (vfs_open_volume(NULL, NULL, &volume) != VFS_INVALID_ARGUMENT) return 3;
    if (vfs_open_volume("runtime", NULL, NULL) != VFS_INVALID_ARGUMENT) return 4;

    rc = vfs_open_volume("runtime", NULL, &volume);
    if (rc != VFS_OK || volume == 0) return 5;

    /* Unmounted volume must not fake a successful open. */
    rc = vfs_open_path(volume, k_vpath, 0, &file);
    if (rc == VFS_OK) return 6;
    if (file != 0) return 7;

    rc = vfs_open_entry(volume, 0, 0, &file);
    if (rc != VFS_INVALID_ARGUMENT) return 8;

    n = 1;
    rc = vfs_read_at(0, 0, bytes, sizeof(bytes), &n);
    if (rc == VFS_OK || n != 0) return 9;

    rc = vfs_mount_pack(volume, pack_path, 10, 0);
    if (rc != VFS_OK) return 10;

    vfs_stat_t st;
    memset(&st, 0, sizeof(st));
    st.struct_size = (uint32_t)sizeof(st);
    rc = vfs_stat_path(volume, k_vpath, &st);
    if (rc != VFS_OK) return 11;
    if (st.file_entry != k_entry) return 12;
    if (st.size != sizeof(k_payload) - 1) return 13;

    memset(&st, 0, sizeof(st));
    st.struct_size = (uint32_t)sizeof(st);
    rc = vfs_stat_entry(volume, k_entry, &st);
    if (rc != VFS_OK || st.size != sizeof(k_payload) - 1) return 14;

    rc = vfs_open_path(volume, k_vpath, 0, &file);
    if (rc != VFS_OK || file == 0) return 15;

    n = 0;
    memset(bytes, 0, sizeof(bytes));
    rc = vfs_read_at(file, 0, bytes, sizeof(bytes), &n);
    if (rc != VFS_OK || n != sizeof(k_payload) - 1) return 16;
    if (memcmp(bytes, k_payload, sizeof(k_payload) - 1) != 0) return 17;

    rc = vfs_open_entry(volume, k_entry, 0, &file_by_entry);
    if (rc != VFS_OK || file_by_entry == 0) return 18;

    n = 0;
    memset(bytes, 0, sizeof(bytes));
    rc = vfs_read_at(file_by_entry, 0, bytes, sizeof(bytes), &n);
    if (rc != VFS_OK || n != sizeof(k_payload) - 1) return 19;
    if (memcmp(bytes, k_payload, sizeof(k_payload) - 1) != 0) return 20;

    if (vfs_close_volume(volume) != VFS_BUSY) return 21;
    if (vfs_close_file(file) != VFS_OK) return 22;
    if (vfs_close_file(file_by_entry) != VFS_OK) return 23;
    if (vfs_close_volume(volume) != VFS_OK) return 24;
    if (vfs_close_volume(volume) != VFS_INVALID_ARGUMENT) return 25;

    /* ---- patch: error paths ---- */
    vfs_patch_t patch = 0;
    vfs_patch_progress_t prog;
    const char* diffs[1];
    diffs[0] = diff_path;

    if (vfs_patch_begin(NULL, NULL, diffs, 1, NULL, &patch) != VFS_INVALID_ARGUMENT) return 30;
    if (vfs_patch_begin(pack_path, NULL, diffs, 0, NULL, &patch) != VFS_INVALID_ARGUMENT) return 31;
    if (vfs_patch_begin(pack_path, NULL, diffs, 1, NULL, NULL) != VFS_INVALID_ARGUMENT) return 32;
    if (vfs_patch_poll(0, &prog) != VFS_INVALID_ARGUMENT) return 33;
    if (vfs_patch_wait(12345, 0) != VFS_INVALID_ARGUMENT) return 34;
    if (vfs_patch_cancel(12345) != VFS_INVALID_ARGUMENT) return 35;
    if (vfs_patch_end(12345) != VFS_INVALID_ARGUMENT) return 36;

    /* Missing DiffPack: begin succeeds, the background run fails with NOT_FOUND. */
    const char* missing[1];
    missing[0] = ".zig-cache/vfs_cabi_smoke_no_such_diff";
    if (vfs_patch_begin(pack_path, NULL, missing, 1, NULL, &patch) != VFS_OK || patch == 0) return 37;
    if (vfs_patch_wait(patch, 30000) != VFS_OK) return 38;
    memset(&prog, 0, sizeof(prog));
    prog.struct_size = (uint32_t)sizeof(prog);
    if (vfs_patch_poll(patch, &prog) != VFS_OK) return 39;
    if (prog.state != VFS_PATCH_FAILED || prog.last_status != VFS_NOT_FOUND) return 40;
    if (vfs_patch_end(patch) != VFS_NOT_FOUND) return 41;
    if (vfs_patch_end(patch) != VFS_INVALID_ARGUMENT) return 42;

    /* ---- patch: begin -> poll until done -> end ---- */
    vfs_patch_options_t popts;
    memset(&popts, 0, sizeof(popts));
    popts.struct_size = (uint32_t)sizeof(popts);
    popts.flags = VFS_PATCH_IN_MEMORY | VFS_PATCH_OPTIMIZE;
    popts.threads = 2;
    popts.verify = VFS_PATCH_VERIFY_TOUCHED;
    patch = 0;
    if (vfs_patch_begin(pack_path, NULL, diffs, 1, &popts, &patch) != VFS_OK || patch == 0) return 43;
    for (;;) {
        memset(&prog, 0, sizeof(prog));
        prog.struct_size = (uint32_t)sizeof(prog);
        if (vfs_patch_poll(patch, &prog) != VFS_OK) return 44;
        if (prog.state != VFS_PATCH_RUNNING) break;
        if (vfs_patch_wait(patch, 10) == VFS_INVALID_ARGUMENT) return 45;
    }
    if (prog.state != VFS_PATCH_DONE || prog.last_status != VFS_OK) return 46;
    if (prog.units_total == 0 || prog.units_done != prog.units_total) return 47;
    if (prog.from_version != 1 || prog.to_version != 2) return 48;
    if (vfs_patch_end(patch) != VFS_OK) return 49;

    /* The patched pack now serves the v2 payload. */
    volume = 0;
    if (vfs_open_volume("runtime2", NULL, &volume) != VFS_OK) return 50;
    if (vfs_mount_pack(volume, pack_path, 10, 0) != VFS_OK) return 51;
    memset(bytes, 0, sizeof(bytes));
    if (read_all(volume, bytes, sizeof(bytes), &n) != VFS_OK) return 52;
    if (n != sizeof(k_payload_v2) - 1) return 53;
    if (memcmp(bytes, k_payload_v2, sizeof(k_payload_v2) - 1) != 0) return 54;
    if (vfs_close_volume(volume) != VFS_OK) return 55;

    /* Re-applying is a no-op that still completes. */
    patch = 0;
    if (vfs_patch_begin(pack_path, NULL, diffs, 1, &popts, &patch) != VFS_OK) return 56;
    if (vfs_patch_wait(patch, 30000) != VFS_OK) return 57;
    if (vfs_patch_end(patch) != VFS_OK) return 58;

    return 0;
}
