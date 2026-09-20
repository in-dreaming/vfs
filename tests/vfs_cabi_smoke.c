#include "vfs.h"

#include <stdint.h>
#include <string.h>

/*
 * C ABI is read/mount only. Pack creation is done by the build step
 * (`vfs put-file`) before this smoke runs; see also tests/vfs_pack_roundtrip.zig.
 */
static const char k_payload[] = "hello-vfs-cabi";
static const char k_vpath[] = "/textures/a.bin";
static const uint64_t k_entry = 1001;

int main(int argc, char** argv) {
    if (argc != 2) return 2;

    const char* pack_path = argv[1];
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

    return 0;
}
