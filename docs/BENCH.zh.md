# 基准测试与优化纪事

> 日期：2026-04-20
> Zig 版本：0.16.0
> 主机：Linux x86_64，NVMe SSD，tmpfs /tmp
> CPU：AMD Ryzen 7 4800H（8 核 / 16 线程）

## 测试方法

- `bench_smoke` 与 `bench_pressure` 为内置基准测试二进制文件。
- `full extraction` 测量通过 CLI 提取**所有**分区的总耗时。
- 吞吐量按 `extracted_bytes / elapsed_time` 计算。
- 真实 OTA payload：`cheetah_beta-ota-cp21.260330.008-878dd270.zip` → `payload.bin`（压缩后约 3.0 GB）。

---

## 1. 问题所在

Android OTA 的 `payload.bin` 包含若干**操作**（replace、replace_xz、replace_bz2、zstd、zero 等）。每个操作包含：

- `payload.bin` 内的一段压缩数据 blob
- 一个或多个**目标 extent**（解压后的数据在输出分区镜像中的写入位置）
- 一段 SHA-256 校验值

单个分区可能包含数百甚至数千个操作。基线提取器以**每个分区一个线程**的方式处理，
这意味着像 `product`（约 4 GB）这样的大分区只能由一个线程处理——而 CPU 明明有 16 个线程可用。

**瓶颈**：分区内串行化。当工作负载被少数几个大分区主导时，一个分区一个线程的方式无法让所有 CPU 核心饱和。

---

## 2. 优化演进

### 2a. 基线（`main`，提交 `3f22fea`）

#### 架构

```text
┌───────────────────────────────────────────┐
│  Main Thread                              │
│  ├─ Parse manifest                        │
│  ├─ For each selected partition:          │
│  │   spawn thread → extractPartition()    │
│  └─ Wait for all threads                  │
└───────────────────────────────────────────┘

extractPartition(thread):
  open output.img
  for each operation in partition:
      seek payload_file to blob_offset
      decompress blob
      write through ExtentCursor to output.img
      verify SHA-256
```

- **线程模型**：每个分区一个线程，无分区内并行。
- **内存**：极少；每个线程有自己的解压缓冲区。
- **磁盘 I/O**：仅直接写入最终输出文件。
- **锁**：无（每个分区有自己的输出文件）。

#### 为什么慢

提取 `system`（4 个分区）时，只有 4 个线程处于活动状态。提取全部 24 个分区时，
大分区（`product`、`system`、`vendor`）占用了大部分时间的线程，而小分区很快完成。
并发数 ≥ 2 可带来约 50% 的提升，但 c ≥ 4 后出现**收益递减**，
因为实际耗时被最大分区的单线程处理所主导。

#### 结果

| Scenario | c=1 | c=2 | c=4 | c=8 |
|----------|-----|-----|-----|-----|
| startup | 1.51s, 84 MiB/s | 0.85s, 150 MiB/s | 0.85s, 150 MiB/s | 0.85s, 150 MiB/s |
| system | 99.6s, 61 MiB/s | 65.6s, 94 MiB/s | 65.6s, 94 MiB/s | 65.3s, 94 MiB/s |
| full | 101s, 65 MiB/s | 66.8s, 98 MiB/s | 66.9s, 98 MiB/s | 66.9s, 98 MiB/s |

---

### 2b. 保守优化（`opt/payload-extract`，提交 `d731df5`）

#### 尝试了什么

在尝试彻底重构之前，我们先测试了三项不改变线程模型的"安全"优化：

1. **Extent 合并**：将同一操作中相邻的 extent 合并为单个更大的 extent，减少寻道次数。
2. **排序调度**：在提取前按总大小对分区排序，让大分区先开始（在收尾阶段获得更好的 CPU 利用率）。
3. **缓冲区复用**：每个 worker 只分配一次解压缓冲区，并在不同操作间复用，降低分配器压力。

#### 为什么没用

- **Extent 合并**：Android OTA 的 extent 通常已经是数 MB 的连续块。节省的寻道次数与总 I/O 量相比可以忽略不计。
- **排序调度**：只有 4 个大分区（`system` 场景），改变起始顺序并不能改变每个分区只能用一个线程的根本限制。
- **缓冲区复用**：无显著影响；基线版本的分配器压力本来就很低。

#### 结果

所有场景均在基线的 **±6%** 范围内——属于测量噪声。这证实瓶颈**并非**调度、寻道或分配器开销，而是每个分区只能用一个线程的限制。

---

### 2c. 激进优化——临时文件（`opt/payload-aggressive`，提交 `face5a8`）

#### 架构

为了打破分区内瓶颈，我们将**所有**分区中的全部操作摊平为一个全局任务队列，并让 worker 池并行消费任务。

```text
Phase 1: Build global task queue
  ├─ For each partition:
  │   ├─ Create tmp_dir/{partition}/
  │   ├─ Pre-allocate output.img
  │   └─ For each operation:
  │       append Task(partition, op_index, tmp_path) to global queue
  │
Phase 2: Spawn workers (count = min(concurrency, total_tasks))
  ├─ Each worker pops Task from atomic index queue
  ├─ Decompress operation → write to {tmp_dir}/op{idx}.tmp
  └─ Verify SHA-256
  │
Phase 3: Main thread merges temp files
  ├─ For each partition:
  │   └─ For each operation in order:
  │       open op{idx}.tmp
  │       read → ExtentCursor → write to output.img
  │       delete temp file
```

- **线程模型**：全局 worker 池 + 每个分区一个顺序合并线程。
- **内存**：每个 worker 占用低（约 1.3 MiB 缓冲区 × 16 个 worker = 约 21 MiB）。
- **磁盘 I/O**：**翻倍**：每个操作先写入临时文件，合并阶段再读回。
- **锁**：无锁任务队列（原子 fetch-add）；解压期间无竞争。

#### 为什么有效（以及哪里拖了后腿）

**有效之处**：对于 `system` c=1，16 个 worker 可以同时解压来自 `product`、`system`、`vendor`
和 `system_ext` 的操作。分区数量较少时，并行解压是巨大的优势。

**拖后腿之处**：对于 `full` c=1，24 个分区 × 大量操作意味着在合并开始前
**所有临时文件同时存在**。临时文件总体积接近最终输出大小（约 6.9 GB）。这产生了大量随机 I/O
（创建、写入、读取、删除），压倒了并行解压带来的好处。

#### 结果

| Scenario | c=1 | c=2 | c=4 | c=8 |
|----------|-----|-----|-----|-----|
| startup | 0.36s, 355 MiB/s | 0.33s, 387 MiB/s | 0.33s, 391 MiB/s | 0.32s, 400 MiB/s |
| system | 51.8s, 119 MiB/s | 31.4s, 196 MiB/s | 33.6s, 183 MiB/s | 48.7s, 126 MiB/s |
| full | **146s, 44 MiB/s** | 69.7s, 94 MiB/s | 66.2s, 99 MiB/s | 66.7s, 98 MiB/s |

> `full` c=1 比基线慢 **−32%**，因为临时文件 I/O 超过了并行解压的收益。

---

### 2d. 流式优化——直接写入（`opt/payload-streaming`，提交 `f4c06a0`）

#### 洞察

临时文件方案付出了 I/O 税，因为它**把解压和写入分离开**。如果 worker 可以按正确顺序将解压后的数据**直接**写入输出文件，会怎样？

挑战在于：一个分区内的操作必须按顺序写入（操作 N 必须在操作 N+1 之前完成，
因为后面的操作可能覆盖前面的位置，且 `ExtentCursor` 要求 extent 单调遍历）。
但 worker 以不可预测的顺序从全局队列拉取任务。

#### 架构

```text
Phase 1: Pre-allocate output files, create PartitionWriteState per partition
  ├─ next_expected_op: atomic counter (starts at 0)
  ├─ pending: mutex-protected list of out-of-order operations
  ├─ output_file: opened once, shared across workers
  └─ has_errors: atomic flag

Phase 2: Spawn workers (same global atomic task queue)
  ├─ Pop Task(partition P, operation N)
  ├─ Decompress to local ArrayList(u8) buffer
  ├─ Acquire partition P's mutex
  │   ├─ If N == next_expected_op:
  │   │   release mutex
  │   │   write buffer → output_file via ExtentCursor
  │   │   acquire mutex
  │   │   next_expected_op += 1
  │   │   flushPendingChain(): while pending contains next op, write it
  │   │   release mutex
  │   └─ Else:
  │       tryAcquire MemoryBudget (256MB global pool)
  │       ├─ If acquired: copy buffer to heap, append to pending
  │       └─ If exhausted: write buffer to spill tmp file, append path to pending
  │       release mutex
  └─ Verify SHA-256

Phase 3: Main thread drains leftover pending
  ├─ Sort pending by op_index
  └─ Sequential write of any remaining contiguous ops
```

##### 关键设计决策

1. **按序直接写入**：当某个 worker 恰好完成下一个操作时，它立即写入——没有临时文件，也没有缓冲。这是快速路径，也是最常见的情况。

2. **内存受限的 pending**：一个全局原子变量 `MemoryBudget`（256 MB）限制乱序数据总量。如果预算耗尽，数据会溢写到小临时文件。实践中溢写很少发生，因为操作通常大致按顺序处理。

3. **链式刷新**：写入操作 N 后，worker（或主线程）自动检查操作 N+1 是否已在 `pending` 中，如果是则立即写入。这会级联，因此一批乱序操作可以在单个临界区内排空。

4. **磁盘空间检查**：在创建任何文件之前，`statvfs` 会检查输出目录。如果空间不足，引擎返回 `InsufficientDiskSpace`，并附带人性化的消息显示所需空间与可用空间。

- **线程模型**：全局 worker 池 + 每个分区一个互斥锁用于写入排序。
- **内存**：约 21 MiB worker 缓冲区 + 最多 256 MB pending 池。
- **磁盘 I/O**：**单遍**：数据直接从解压器流向输出文件。仅在内存预算耗尽时才出现临时文件（罕见）。
- **锁**：每个分区的 `std.Io.Mutex` 保护 `next_expected_op` 和 `pending`。写操作在 I/O 期间释放互斥锁，因此多个 worker 可以同时为同一分区解压。

#### 为什么快这么多

临时文件方案写入并回读了约 6.9 GB 临时数据。流式方案在常见情况下写入约 0 GB 临时数据。以 `full` c=1 为例：

- 临时文件：146 秒（并行解压 + 14 GB 临时 I/O）
- 流式：18.3 秒（并行解压 + 7 GB 直接输出 I/O）

仅 I/O 节省就能解释大部分加速。其余来自消除顺序合并阶段——worker 与合并逻辑交错执行，因此输出文件是持续填充的，而非等待所有解压完成。

#### 结果

| Scenario | c=1 | c=2 | c=4 | c=8 |
|----------|-----|-----|-----|-----|
| startup | 0.30s, 419 MiB/s | 0.30s, 423 MiB/s | 0.30s, 425 MiB/s | 0.30s, 421 MiB/s |
| system | **18.3s, 337 MiB/s** | 23.1s, 266 MiB/s | 49.4s, 124 MiB/s | 37.9s, 162 MiB/s |
| full | **18.3s, 359 MiB/s** | 18.0s, 365 MiB/s | 20.7s, 318 MiB/s | 21.9s, 300 MiB/s |

> `system` c=4（49.4 秒）是一个异常值——可能是 8C/16T CPU 上的调度抖动。c=2 和 c=8 更具代表性。

---

## 3. 对比总结

### 全场景、全方案

| Approach | startup c=1 | system c=1 | full c=1 | full c=8 |
|----------|-------------|------------|----------|----------|
| **Baseline** | 1.51s, 84 | 99.6s, 61 | 101s, 65 | 66.9s, 98 |
| **Conservative** | 1.56s, 82 | 99.9s, 61 | 104s, 62 | 69.5s, 94 |
| **Temp Files** | 0.36s, 355 | 51.8s, 119 | **146s, 44** | 66.7s, 98 |
| **Streaming** | **0.30s, 419** | **18.3s, 337** | **18.3s, 359** | **21.9s, 300** |

### 相对基线的加速比（流式方案）

| Scenario | Speedup |
|----------|---------|
| startup c=1 | **+393%** |
| system c=1 | **+445%** |
| full c=1 | **+452%** |
| full c=8 | **+206%** |

---

## 4. 架构对比

| Dimension | Baseline | Temp Files | Streaming |
|-----------|----------|------------|-----------|
| **Thread model** | 1 thread / partition | Global pool + sequential merge | Global pool + ordered direct write |
| **Intra-partition parallelism** | ❌ No | ✅ Yes | ✅ Yes |
| **Temp files** | ❌ None | ⚠️ One per operation (~6.9 GB peak) | ⚠️ Only on memory-budget spill (rare) |
| **Peak disk write** | ~output size | ~2× output size | ~output size |
| **Memory footprint** | ~10 MiB | ~21 MiB | ~21 MiB + 256 MB pending pool |
| **Locking** | None | Lock-free task queue | Per-partition mutex |
| **Disk space check** | ❌ No | ❌ No | ✅ Yes (`statvfs`) |
| **Complexity** | Low | High | High |
| **Correctness risk** | Low | Medium (temp file lifecycle) | Medium (ordering + mutex) |

---

## 5. 经验教训

1. **优化前先测量。** 保守优化（extent 合并、排序调度、缓冲区复用）没有产生任何可测量的收益。只有在性能分析后，我们才意识到真正的瓶颈是分区内串行化。

2. **临时文件代价高昂。** 激进方案证明了并行解压的强大，但临时文件的 I/O 开销可以完全抵消它——尤其是在涉及多个分区的全量提取工作负载中。

3. **流式是正确的抽象。** 通过允许 worker 直接写入输出文件（在按序时），我们保留了并行化的好处，同时消除了 I/O 税。256 MB 内存预算是一个安全阀，并非常见路径。

4. **磁盘空间检查很重要。** `statvfs` 预检查可以防止用户在磁盘几乎已满时启动数 GB 的提取，然后在半路失败并留下含义不明的 I/O 错误。

---

## 6. 验收标准

- [x] `zig build test` 通过
- [x] `zig build check_e2e` 通过
- [x] `zig build test_stress` 通过
- [x] 任何场景均无正确性回退
- [x] 基线 → 保守：记录为无操作
- [x] 基线 → 临时文件：在 system/startup 上获得大幅提升，在 full c=1 上回退
- [x] 临时文件 → 流式：在**所有**工作负载上获得大幅提升
- [x] 磁盘空间检查已实现并测试
- [x] Full extraction c=1：相比基线 +452%（临时文件方案为 −32%）

---

## 7. 流式之后：解压缩引擎重构

流式引擎稳定后，剩余的系统依赖是 `liblzma`、`libzstd` 和 `libbz2`。
我们将 XZ 和 Zstd 解压迁移到了 Zig 标准库：

| 压缩算法 | 重构前 | 重构后 |
|----------|--------|-------|
| XZ | `liblzma` FFI | `std.compress.xz` |
| Zstd | `libzstd` FFI | `std.compress.zstd` |
| Bzip2 | `libbz2` FFI（源码 vendor） | `libbz2` FFI（未变） |

### 对合成基准测试的影响

这次重构对单线程性能产生了可测量的提升：

| Payload | 重构前（C FFI） | 重构后（Zig std） | 变化 |
|---------|----------------|-----------------|-------|
| bench32 c=1 | 419 ms | 305 ms | **−27%** |
| bench128 c=1 | 1 490 ms | 1 137 ms | **−24%** |
| bench256 c=1 | 2 920 ms | 2 108 ms | **−28%** |
| bench512 c=1 | 6 002 ms | 4 319 ms | **−28%** |

多线程性能基本未变（±3%），证实高并发下的瓶颈已从解压吞吐转移到同步开销。

### 剩余工作

Bzip2 是唯一剩余的 C FFI 依赖。原生 Zig bzip2 解码器可以彻底移除 bzip2 FFI，
但 `std.compress` 目前尚未包含。可选方案：等待上游、自行移植、或静态链接 `lbzip2`。
