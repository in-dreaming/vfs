# Task 01：基础格式、Endian、CRC、Hash

## 1. 任务目标

实现 DB 文件格式所需的基础工具：

- fixed-size disk struct 约束。
- little-endian encode/decode。
- magic/version 常量。
- CRC/checksum。
- Key128。
- secondary hash64。
- 对齐工具。

本任务不读写完整 DB 文件。

## 2. 必读上下文

执行前必须阅读：

- `docs/design/db/tasks/setup.md`
- `docs/design/db_arch.md` 的“数据模型”和“Zig 实现约束”

## 3. 硬性禁止

- 禁止 mock/moke。
- 禁止 callback。
- 禁止使用伪 CRC。
- 禁止使用会因平台 endian 改变而改变磁盘结果的裸内存写入。

## 4. 实现范围

实现：

- `Key128`
- `IndexInfo`
- `Durability`
- `Status` / 内部错误映射基础
- magic 常量
- alignment helper
- little-endian read/write helper
- CRC32C 或明确选择的 CRC32 算法
- `mixHash128To64`
- `ceilLog2`
- `alignUp`
- `checkedAdd`
- `checkedMul`

CRC 算法必须明确写在注释或文档中，测试向量必须固定。

## 5. 数据结构要求

~~~zig
pub const Key128 = extern struct {
    hi: u64,
    lo: u64,
};

pub const IndexInfo = extern struct {
    data_db_id: u32,
    flags: u32,
    offset: u64,
    stored_size: u32,
    raw_size: u32,
    version: u64,
    crc: u32,
    codec: u16,
    reserved: u16,
};
~~~

要求：

- `@sizeOf(Key128) == 16`
- `@sizeOf(IndexInfo) == 40`
- 若实际 size 不同，必须调整字段或文档，不允许含糊。

## 6. Hash 要求

`mixHash128To64(key)` 用于 index bucket 和 delta hash。

要求：

- deterministic。
- 跨平台一致。
- 不依赖随机 seed。
- 不依赖进程地址。
- 输入相同，所有平台输出相同。

V1 可以使用固定实现，例如 SplitMix64 风格组合：

~~~text
h = mix64(key.hi ^ rotate_left(key.lo, 32) ^ fixed_seed)
~~~

具体算法必须写入代码注释，并有测试向量。

## 7. 验证流程

必须测试：

1. `Key128` size/alignment。
2. `IndexInfo` size/alignment。
3. little-endian u16/u32/u64 encode/decode。
4. CRC 对固定字符串输出固定结果。
5. CRC 对空输入输出固定结果。
6. `mixHash128To64` 对至少 8 个固定 key 输出固定结果。
7. `alignUp` 正确处理 0、1、15、16、17、4095、4096、4097。
8. checked arithmetic overflow 必须返回错误或 false，不能 wrap。

## 8. 完成标准

- 基础格式工具可被后续任务直接复用。
- 所有测试向量固定。
- 没有 callback。
- 没有 mock/moke。
- 没有平台相关不确定行为。

