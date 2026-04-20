# Benchmark Results

> Date: 2026-04-20  
> Zig version: 0.16.0  
> Host: Linux x86_64, NVMe SSD, tmpfs /tmp  
> CPU: AMD Ryzen 7 4800H (8 cores / 16 threads)

## Methodology

- `bench_smoke` and `bench_pressure` are built-in benchmark binaries.
- `full extraction` measures total time to extract **all** partitions via CLI.
- Throughput is computed as `extracted_bytes / elapsed_time`.
- Real OTA payload: `cheetah_beta-ota-cp21.260330.008-878dd270.zip` → `payload.bin` (~3.0 GB compressed).

---

## 1. Sample Payload (`tests/data/generated/smoke1/payload.bin`)

Very small synthetic payload (~68 KiB total output). Numbers are dominated by overhead, not I/O throughput.

### bench_smoke (partitions: boot, vbmeta, vendor_boot)

| Concurrency | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) |
|-------------|-------------:|-----------:|-------------------:|-------------------:|
| 1           | 50           | 24         | 480                | 0                  |
| 4           | 50           | 24         | 480                | 0                  |

### bench_pressure — startup (boot, vbmeta, vendor_boot)

| Concurrency | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) |
|-------------|-------------:|-----------:|-------------------:|-------------------:|
| 1           | 54           | 24         | 444                | 0                  |
| 2           | 50           | 24         | 480                | 0                  |
| 4           | 50           | 24         | 480                | 0                  |
| 8           | 50           | 24         | 480                | 0                  |

### bench_pressure — system (system, vendor, product, system_ext)

| Concurrency | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) |
|-------------|-------------:|-----------:|-------------------:|-------------------:|
| 1           | 50           | 44         | 880                | 0                  |
| 2           | 50           | 44         | 880                | 0                  |
| 4           | 51           | 44         | 862                | 0                  |
| 8           | 51           | 44         | 862                | 0                  |

---

## 2. Real OTA Payload (`payload.bin`)

- Input size: ~3.0 GB (compressed payload.bin)
- Total output (all partitions): ~6.9 GB
- Partitions (24 total): abl, bl1, bl2, bl31, boot(64MB), dtbo, gsa, init_boot, ldfw, modem(101MB), pbl, product(~4.0GB), pvmfw, system(~1.1GB), system_dlkm, system_ext(~369MB), tzsw, vbmeta, vbmeta_system, vbmeta_vendor, vendor(~785MB), vendor_boot, vendor_dlkm, vendor_kernel_boot

### 2a. Baseline (`main` branch, commit `3f22fea`)

#### bench_smoke (boot, vbmeta, vendor_boot)

| c | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) |
|---|-------------:|-----------:|-------------------:|-------------------:|
| 1 | 1,506        | 131,084    | 87,041             | 85                 |
| 4 | 852          | 131,084    | 153,854            | 150                |

#### bench_pressure — startup

| c | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) |
|---|-------------:|-----------:|-------------------:|-------------------:|
| 1 | 1,509        | 131,084    | 86,868             | 84                 |
| 2 | 853          | 131,084    | 153,674            | 150                |
| 4 | 852          | 131,084    | 153,854            | 150                |
| 8 | 853          | 131,084    | 153,674            | 150                |

#### bench_pressure — system

| c | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) |
|---|-------------:|-----------:|-------------------:|-------------------:|
| 1 | 99,649       | 6,319,356  | 63,416             | 61                 |
| 2 | 65,600       | 6,319,356  | 96,331             | 94                 |
| 4 | 65,554       | 6,319,356  | 96,399             | 94                 |
| 8 | 65,314       | 6,319,356  | 96,753             | 94                 |

#### Full Extraction

| c | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) |
|---|-------------:|-----------:|-------------------:|-------------------:|
| 1 | 100,975      | 6,724,212  | 66,592             | 65                 |
| 2 | 66,782       | 6,724,212  | 100,688            | 98                 |
| 4 | 66,885       | 6,724,212  | 100,533            | 98                 |
| 8 | 66,911       | 6,724,212  | 100,494            | 98                 |

---

### 2b. Conservative Optimization (`opt/payload-extract`, commit `d731df5`)

Extent merging, sort scheduling, buffer reuse. No measurable improvement.

#### bench_smoke

| c | Elapsed (ms) | Δ vs baseline |
|---|-------------:|---------------|
| 1 | 1,505        | ≈ 0%          |
| 4 | 854          | ≈ 0%          |

#### bench_pressure — startup

| c | Elapsed (ms) | Δ vs baseline |
|---|-------------:|---------------|
| 1 | 1,559        | −3%           |
| 2 | 853          | ≈ 0%          |
| 4 | 853          | ≈ 0%          |
| 8 | 854          | ≈ 0%          |

#### bench_pressure — system

| c | Elapsed (ms) | Δ vs baseline |
|---|-------------:|---------------|
| 1 | 99,858       | ≈ 0%          |
| 2 | 67,863       | +3%           |
| 4 | 68,559       | −4%           |
| 8 | 69,693       | −6%           |

#### Full Extraction

| c | Elapsed (ms) | Δ vs baseline |
|---|-------------:|---------------|
| 1 | 104,358      | −3%           |
| 2 | 68,707       | −2%           |
| 4 | 68,593       | −2%           |
| 8 | 69,461       | −3%           |

---

### 2c. Aggressive Optimization (`opt/payload-aggressive`, commit `140449c`)

Global worker pool flattening all operations across partitions, per-operation temp files, sequential merge. Worker count = `max(concurrency, cpu_count)`.

#### bench_smoke (boot, vbmeta, vendor_boot)

| c | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) | Δ vs baseline |
|---|-------------:|-----------:|-------------------:|-------------------:|---------------|
| 1 | 1,437        | 131,084    | 91,221             | 89                 | **+5%**       |
| 2 | 842          | 131,084    | 155,682            | 152                | **+1%**       |
| 4 | 857          | 131,084    | 152,959            | 149                | ≈ 0%          |
| 8 | 858          | 131,084    | 152,781            | 149                | ≈ 0%          |

#### bench_pressure — startup

| c | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) | Δ vs baseline |
|---|-------------:|-----------:|-------------------:|-------------------:|---------------|
| 1 | 360          | 131,084    | 364,122            | 355                | **+326%**     |
| 2 | 330          | 131,084    | 397,224            | 387                | **+158%**     |
| 4 | 327          | 131,084    | 400,869            | 391                | **+160%**     |
| 8 | 320          | 131,084    | 409,637            | 400                | **+167%**     |

#### bench_pressure — system

| c | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) | Δ vs baseline |
|---|-------------:|-----------:|-------------------:|-------------------:|---------------|
| 1 | 51,826       | 6,319,356  | 121,934            | 119                | **+93%**      |
| 2 | 31,408       | 6,319,356  | 201,202            | 196                | **+108%**     |
| 4 | 33,562       | 6,319,356  | 188,288            | 183                | **+94%**      |
| 8 | 48,731       | 6,319,356  | 129,679            | 126                | **+33%**      |

#### Full Extraction

| c | Elapsed (ms) | Size (KiB) | Throughput (KiB/s) | Throughput (MiB/s) | Δ vs baseline |
|---|-------------:|-----------:|-------------------:|-------------------:|---------------|
| 1 | 146,640      | 6,724,212  | 45,855             | 44                 | **−32%**      |
| 2 | 69,748       | 6,724,212  | 96,407             | 94                 | −4%           |
| 4 | 66,244       | 6,724,212  | 101,506            | 99                 | **+1%**       |
| 8 | 66,673       | 6,724,212  | 100,853            | 98                 | ≈ 0%          |

---

## 3. Summary & Analysis

### Where It Wins

| Scenario | Best Gain | Why |
|----------|-----------|-----|
| **startup c=1** | **+326%** | 3 small partitions → temp file overhead is tiny, 16 workers decompress all ops in parallel |
| **system c=2** | **+108%** | 4 large partitions → each gets ~4 workers, all I/O is parallelized |
| **system c=1** | **+93%** | Same as above, but only 1 consumer; 16 workers still saturate decompression |

### Where It Loses

| Scenario | Loss | Why |
|----------|------|-----|
| **full c=1** | **−32%** | 24 partitions × many operations = massive temp file I/O overhead; single-threaded merge per partition adds latency that is not amortized by parallel decompression at c=1 |
| **system c=8** | **+33%** | Diminishing returns: 16 workers fight for disk bandwidth on the same 4 output files |

### Root Cause: Temp File I/O Tax

Every operation writes to a temp file and is later read back during merge. For **full extraction c=1**:
- Decompression is parallel (good)
- But merge is single-threaded per partition, and the temp directory is on disk
- 24 partitions × many temp files = lots of random I/O (create, write, read, delete)
- The overhead exceeds the benefit of parallel decompression

For **system c=1/2**, the partition count is small (4), so temp file overhead is manageable and parallel decompression dominates.

### Full Extraction Parity at c≥4

At c=4/8, the aggressive approach is roughly on par with baseline. The temp file overhead is amortized across more concurrent work, but the gain from intra-partition parallelism is consumed by disk contention.

---

## 4. Architectural Trade-off

| Approach | Pros | Cons | Best For |
|----------|------|------|----------|
| **Baseline** (thread-per-partition) | Simple, no temp files, merge is free | Cannot parallelize within a partition | Many small partitions, low concurrency |
| **Aggressive** (global pool + temp files) | Massive speedup on large partitions | Temp I/O tax, merge bottleneck, complex | Few large partitions, high single-thread load |

The temp file approach is a **net win for realistic workloads** (users typically extract 1–4 large partitions at a time, not all 24). For a true full-extraction-at-c=1 use case, a memory-buffered pipeline (ring buffers between workers and a merge thread) would eliminate the temp file tax, but significantly increases complexity (memory pressure, backpressure, bounded buffer sizes).

---

## 5. Acceptance Criteria

- [x] `zig build test` passes
- [x] `zig build check_e2e` passes
- [x] `zig build test_stress` passes
- [x] No correctness regressions in any scenario
- [x] Major speedups on primary target workloads (system/startup)
- [x] Full extraction parity at c≥4
