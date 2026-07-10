# Task 07：KV Open/Get/Put/Delete 与 C ABI

## 1. 任务目标

集成 manifest、data file、base index、delta journal、delta index，形成可用 V1 KV DB。

对外提供 C ABI：

- open
- close
- get size
- get into caller buffer
- put
- delete

本任务禁止 callback，因此不提供 streaming callback API。

本任务实现的是独立 DB 库 C ABI。所有导出符号必须使用 `db_*` 前缀。禁止导出 `vfs_*`、`vfs_db_*` 或任何未来 VFS 库接口。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `task_02_data_record_append.md`
- `task_03_manifest.md`
- `task_04_index_file_container.md`
- `task_04_base_index.md`
- `task_05_delta_journal.md`
- `task_06_delta_index.md`
- `docs/design/db_arch.md` 的“C ABI”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止返回内部 mmap 指针给 C。
- 禁止 C 调用方必须使用 Zig allocator。
- 禁止 get 时跳过 record key/crc 校验。

## 4. 实现范围

实现 Zig 内部 API：

~~~zig
pub const KvDb = struct {
    pub fn open(path: []const u8, options: OpenOptions) !KvDb;
    pub fn close(self: *KvDb) !void;
    pub fn getSize(self: *KvDb, key: Key128) !u64;
    pub fn getInto(self: *KvDb, key: Key128, dst: []u8) !usize;
    pub fn put(self: *KvDb, key: Key128, data: []const u8, options: PutOptions) !void;
    pub fn delete(self: *KvDb, key: Key128, options: DeleteOptions) !void;
};
~~~

实现 C ABI：

~~~c
typedef struct db db_t;

typedef struct db_key128 {
    uint64_t hi;
    uint64_t lo;
} db_key128_t;

typedef struct db_open_options {
    uint32_t struct_size;
    uint32_t flags;
    uint32_t durability;
    uint32_t reserved0;
    uint64_t max_delta_entries;
    uint64_t data_file_target_size;
} db_open_options_t;

int db_open(const char* path, const db_open_options_t* options, db_t** out_db);
int db_close(db_t* db);

int db_get_size(db_t* db, db_key128_t key, uint64_t* out_size);
int db_get_into(db_t* db, db_key128_t key, void* dst, uint64_t dst_size, uint64_t* out_written);

int db_put(db_t* db, db_key128_t key, const void* data, uint64_t size, uint32_t flags);
int db_delete(db_t* db, db_key128_t key);
~~~

不要实现 `db_get_stream(callback)`。

## 5. Lookup 规则

~~~text
1. enter read epoch，如果 epoch 尚未实现，使用占位真实实现记录 active reader，不能 mock。
2. 查 active delta。
3. 若 delta tombstone，返回 not_found。
4. 若 delta put，读取对应 data record。
5. 若 delta not_found，查 base。
6. base found 后读取 data record。
7. 校验 record key、crc、version。
8. exit read epoch。
~~~

如果 base 尚为空，必须仍走同一逻辑，不得特殊 mock。

## 6. Put 规则

~~~text
1. key lock。
2. data append record；如果 durability == sync，data record、必要文件长度 metadata、DataSuperBlock logical_tail 必须 durable。
3. delta journal append PUT。
4. 如果 durability == sync，delta journal 与 DeltaHeader.journal_tail 必须 durable。
5. delta hash publish。
6. retire old index target。如果 allocator epoch 尚未实现，记录 TODO 并不复用 old block。
7. unlock。
~~~

V1 old record 不复用，但必须保证 overwrite 后 lookup 返回新 record。

## 7. Delete 规则

~~~text
1. key lock。
2. delta journal append DELETE。
3. 如果 durability == sync，delta journal 与 DeltaHeader.journal_tail 必须 durable。
4. delta hash publish tombstone。
5. retire old index target。如果 allocator epoch 尚未实现，记录 TODO 并不复用 old block。
6. unlock。
~~~

## 8. C ABI 状态码

实现明确状态码：

~~~c
enum {
    DB_OK = 0,
    DB_NOT_FOUND = 1,
    DB_INVALID_ARGUMENT = 2,
    DB_IO_ERROR = 3,
    DB_CORRUPTION = 4,
    DB_CHECKSUM_MISMATCH = 5,
    DB_UNSUPPORTED_VERSION = 6,
    DB_BUSY = 7,
    DB_NO_SPACE = 8,
    DB_PERMISSION_DENIED = 9,
    DB_INTERNAL_ERROR = 100,
};
~~~

## 9. 验证流程

必须测试：

1. C ABI open 空 DB。
2. C ABI put 一个 key。
3. C ABI get_size 返回正确 size。
4. C ABI get_into 读回完整数据。
5. get_into buffer 太小返回明确错误或 required size，不能越界。
6. overwrite 同 key 后读到新值。
7. delete 后 get 返回 not_found。
8. 重启 open 后 delta 中数据仍可读。
9. base index 中数据可读。
10. delta tombstone 覆盖 base。
11. payload 损坏后 get 返回 checksum/corruption。
12. 不返回内部指针。
13. 不使用 callback。
14. 不使用 mock/moke。

## 10. 完成标准

- DB V1 可真实创建、打开、put、get、delete。
- C ABI 稳定且无 callback。
- C ABI 只导出 `db_*` 符号，不导出 `vfs_*` 或 `vfs_db_*`。
- get 使用 caller-provided buffer。
- overwrite/delete 语义正确。
