# zpayload-dumper

[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org)

从 Android OTA 更新包中提取分区镜像的命令行工具

Android OTA 更新（特别是 A/B 无缝更新）会把各个分区的更新数据打包成一个特殊的 `payload.bin` 文件，
放在 zip 包里面。这个工具可以读取 `payload.bin`，并把里面每个分区的镜像（比如
`boot.img`、`vbmeta.img`、`system.img` 等）单独提取出来。

## 功能

- 从 `payload.bin` 文件中提取分区镜像
- 也可以直接处理 `.zip` 格式的 OTA 包（会自动找到里面的 `payload.bin`）
- 支持多种压缩格式：Bzip2、XZ、Zstd，以及未压缩数据
- 用 SHA-256 校验提取的数据是否完整
- 可以提取全部分区，也可以只提取你指定的几个
- 支持多线程并行提取，速度更快

## 安装

### 前置条件

- Zig 0.16.0 或更高版本
- `protoc`（Protocol Buffers 编译器），需要支持 upb
- 系统库：`upb`、`utf8_range`、`bz2`
  - XZ 和 Zstd 使用 Zig 原生 `std.compress`（无需系统库）
  - 仅 bzip2 仍需 `libbz2.so`

### 安装系统依赖

#### Arch Linux

```bash
sudo pacman -S --needed protobuf bzip2
```

#### Gentoo

```bash
sudo emerge --ask dev-libs/protobuf app-arch/bzip2
```

#### Ubuntu / Debian / Fedora

从源码编译安装 protobuf：

```bash
# 1. 安装编译依赖
# Ubuntu/Debian:
sudo apt install -y cmake g++ git libbz2-dev
# Fedora:
sudo dnf install -y cmake gcc-c++ git bzip2-devel

# 2. 编译并安装 protobuf（包含 protoc + libupb + upb 生成器）
git clone https://github.com/protocolbuffers/protobuf.git
cd protobuf
git checkout v34.1   # 或更新版本
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -Dprotobuf_BUILD_TESTS=OFF \
  -Dprotobuf_BUILD_SHARED_LIBS=ON \
  -Dprotobuf_BUILD_UPB=ON
cmake --build build -j$(nproc)
sudo cmake --install build

# 3. 编译 zpayload-dumper
cd /path/to/zpayload-dumper
zig build
```

## 编译

```bash
zig build
```

### 增量 OTA 支持（可选）

要启用 `SOURCE_BSDIFF` 增量操作，编译时需加上 `-Dbsdiff` 标志：

```bash
zig build -Dbsdiff
```

`SOURCE_COPY` 增量操作始终可用，无需额外编译标志。

编译完成后，可通过 `zig build run -- ...` 直接运行，或从安装前缀的 `bin/zpayload-dumper` 调用。

> **平台支持：** `main` 分支仅针对 Linux。Windows 交叉编译和原生构建在 [`feat/windows-support`](../../tree/feat/windows-support) 分支维护。
>
> **异步实验：** [`feat/async-engine`](../../tree/feat/async-engine) 分支将手动线程池替换为 `std.Io.Group.concurrent`，并可在上游稳定运行后接入 `std.Io.Uring`（io_uring）。Zig 0.16.0 的 `std.Io.Uring` 需要编译修复 [PR #31764](https://codeberg.org/ziglang/zig/pulls/31764)（`Dir.OpenError` / `Dir.RealPathFileError` 缺少 `ReadOnlyFileSystem`），但即使修复后运行时仍会在 `CancelRegion.init` 的 fiber 上下文切换中崩溃，因此该后端在该分支上保持禁用。

## 用法

### 基本示例

```bash
# 只列出所有分区，不提取
zig build run -- -l payload.bin

# 提取所有分区
zig build run -- -o out payload.bin

# 只提取指定分区
zig build run -- -p boot,vendor -o out payload.bin

# 也可以直接处理 zip 格式的 OTA 包
zig build run -- payload.zip

# 模拟提取（不实际写入，用于测试进度 UI）
zig build run -- --dry-run -p boot,vendor payload.bin
zig build run -- --dry-run payload.zip

# 增量 OTA 提取（需要提供源分区镜像）
zig build run -- --old old_images/ -o new_images/ incremental_payload.bin
zig build run -- --old old_images/ -p boot,vendor -o new_images/ incremental_payload.bin
```

### 选项

| 选项 | 说明 |
|------|------|
| `-h`, `--help` | 显示完整帮助并退出 |
| `-v`, `--version` | 显示版本号并退出 |
| `-l`, `--list` | 列出所有分区后退出 |
| `-p`, `--partitions <csv>` | 只提取指定的分区（用逗号分隔） |
| `-o`, `--output <dir>` | 输出目录（默认：`extracted_YYYYMMDD_HHMMSS`） |
| `--old <dir>` | 源分区镜像目录（增量 OTA 提取必需） |
| `-c`, `--concurrency <n>` | 并行工作线程数（默认：`nproc / 2`，逻辑线程数的一半） |
| `--dry-run` | 模拟提取进度，不实际写入输出（用于测试进度 UI 或验证 payload 可解析性） |
| `--color` | 等价于 `--color=always` |
| `--color=<mode>` | 颜色模式：`auto`、`always`、`never` |
| `--no-color` | 等价于 `--color=never` |
| `--format <mode>` | 输出格式：`text`、`json`（影响 `--version` 和 `--list` 输出） |
| `--format=json` | JSON 输出的简写形式 |

### 错误处理

- 不支持的参数或缺少输入文件时，程序会输出简要的着色 usage 信息，并以退出码 `2` 结束。
- `--help` 和 `--version` 以退出码 `0` 结束。

### 颜色与环境变量

- 参数优先级最高，其次是 `ZPAYLOAD_COLOR`
- 然后是标准终端变量：`CLICOLOR_FORCE`、`NO_COLOR`、`CLICOLOR`
- 都没有时按 `isTTY` 自动判定

支持的环境变量：

- `ZPAYLOAD_COLOR=auto|always|never`
- `NO_COLOR`
- `CLICOLOR=0`
- `CLICOLOR_FORCE=1`

### 临时目录

处理 `.zip` 或 `.tar`/`.tar.gz`/`.tgz` 输入时，程序会先将 `payload.bin` 提取到当前工作目录下 `./.tmp` 的临时目录中。临时目录会自动创建，并在提取完成后自动移除。

### 磁盘空间检查

提取开始前，程序会自动检查输出目录的可用磁盘空间。如果空间不足以容纳所选分区，会立即中止并提示需要多少空间、实际有多少可用空间。

### 进度显示

- **终端（TTY）：** 显示实时的多分区进度条
- **重定向/管道：** 输出简洁的单行日志
- **自动着色：** help 和 CLI 日志都会根据 `isTTY` 自动着色，也可以通过参数或环境变量覆盖

## 开发

`scripts/` 下包含一个独立的 Python 工具集，用于生成 Android OTA `payload.bin` 测试样本。它是标准的 `uv` 管理工程，可以独立于本提取器使用。

完整用法见 [`scripts/README.zh.md`](scripts/README.zh.md)。

### 运行测试

```bash
zig build test
```

### 压力测试

用不同的并行度多次执行提取，检查稳定性：

```bash
zig build test_stress
```

### 端到端校验

完整提取 payload，并用 SHA-256 与预期输出镜像对比：

```bash
zig build check_e2e
```

### 性能测试

快速测试，使用固定的分区集合：

```bash
zig build bench_smoke
```

完整测试矩阵，测试不同分区集合和并行度（1、2、4、8）：

```bash
zig build bench_pressure
```

也可以指定自定义的 payload 路径：

```bash
zig build bench_smoke -- /path/to/payload.bin
zig build bench_pressure -- /path/to/payload.bin
```

### 与 payload-dumper-go 的性能对比

以下数据均为实际运行时间（hyperfine 5 次取均值）。

**测试机器：** AMD Ryzen 7 4800H（8 核 / 16 线程），22 GB DDR4，
ZHITAI TiPlus7100 1TB NVMe SSD，Gentoo Linux（内核 7.0.0-gentoo-dist）。

测试样本是一个 **78 MB** 的合成 payload
（`uv run --project scripts payload-gen sample --total-mb 128`），
覆盖 `REPLACE`、`REPLACE_XZ`、`REPLACE_BZ`、`ZSTD` 和 `ZERO` 五种操作类型。

| 场景 | 并发数 | zpayload-dumper | payload-dumper-go | 加速比 |
|------|--------|-----------------|-------------------|--------|
| `payload.bin` | 1 线程 | **1 137 ms** | 1 378 ms | **1.21 倍** |
| `payload.bin` | 4 线程 | **409 ms** | 467 ms | **1.14 倍** |
| `payload.bin` | 8 线程 | 308 ms | **295 ms** | 0.96 倍 |
| `ota_update.zip` | 4 线程 | 625 ms | **523 ms** | 0.8 倍 |

说明：

- **解压缩引擎重构**：XZ 和 Zstd 从 C FFI（`liblzma`、`libzstd`）迁移到
  Zig 标准库（`std.compress.xz`、`std.compress.zstd`）。这移除了两个系统
  依赖，并将单线程吞吐提升了约 25%。
- **单线程全面领先**：Zig 在 `c=1` 的所有 payload 尺寸上均领先（1.12–1.42×）。
  大 payload（`bench256`、`bench512`）的 `c=2–16` 差距基本消失（±4% 以内）。
- **Go 的调度器在小负载高并发下占优**：`bench32` 在 `c≥4` 时 Go 反超
  （最高 1.31× 于 `c=16`），goroutine 上下文切换开销低于 Zig 的线程池 + 互斥锁。
- **Zip 输入**：zip 解包对两边都有额外开销，而且当前 Go 实现同样更快。

> 完整的 benchmark 矩阵（bench32/128/256/512、不同线程数下的扩展性分析、性能分析）
> 见 [`docs/COMPARISON.md`](docs/COMPARISON.md)。

### 生成测试数据

用于本地测试或持续集成，可以生成合成 payload 和对应的预期输出镜像：

```bash
uv sync --project scripts

# 小型样本（默认，约 56 KB payload）
uv run --project scripts payload-gen sample --name smoke1

# 大型样本，用于性能测试（约 80 MB payload，128 MB 原始数据）
uv run --project scripts payload-gen sample --name bench128 --total-mb 128

# 错误样本
uv run --project scripts payload-gen sample --name bad-magic --scenario invalid_magic
uv run --project scripts payload-gen sample --name fixture-matrix --scenario all --total-mb 32
```

输出会放到 `tests/data/`（该目录被 git 忽略），然后可以验证：

```bash
zig build run -- -o tmp/smoke1_out tests/data/generated/smoke1/payload.bin
zig build run -- -o tmp/smoke1_zip_out tests/data/generated/smoke1/ota_update.zip
```

可以通过下面的命令列出所有合成场景：

```bash
uv run --project scripts payload-gen sample --list-scenarios
```

生成 `SOURCE_BSDIFF` 增量 payload：

```bash
uv run --project scripts payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output test_payload.bin
```

生成可直接做完整流程测试的完整测试样本目录：

```bash
uv run --project scripts payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output tests/data/generated/bsdiff-sample/payload.bin \
  --bundle-dir tests/data/generated/bsdiff-sample
```

生成的目录会同时包含 `payload.bin`、`ota_update.zip`、`old/boot.img`、
`extracted/boot.img` 和 `manifest.textproto`。生成出的 manifest 会带上
`data_sha256_hash` 和 `src_sha256_hash`，因此能验证真实的
`SOURCE_BSDIFF` 校验路径。

## 支持的 Payload 特性

- 格式：`CrAU` 文件头，版本 2
- 通过 `upb` 解析 protobuf 元数据
- 支持的操作类型：
  - `REPLACE` — 原始数据直接复制
  - `REPLACE_XZ` — XZ 压缩数据
  - `REPLACE_BZ` — Bzip2 压缩数据
  - `ZSTD` — Zstd 压缩数据
  - `ZERO` — 全零填充块
  - `SOURCE_COPY` — 增量复制（需要提供 `--old`）
  - `SOURCE_BSDIFF` — 增量 bsdiff 补丁（需要提供 `--old`，编译时加 `-Dbsdiff`）
- 对操作数据进行 SHA-256 校验
- 对增量操作的源镜像数据进行 SHA-256 校验（`src_sha256_hash`）
- 输入支持：
  - 单独的 `payload.bin`
  - 包含 `payload.bin` 的 `.zip` 文件
  - 包含 `payload.bin` 的 `.tar`/`.tar.gz`/`.tgz` 文件

> 各厂商非标准 OTA 格式的兼容性说明（vivo、OPPO、三星、华为、小米、摩托罗拉、索尼等），
> 请参阅 [`docs/ODD_OTA_FORMATS.zh.md`](docs/ODD_OTA_FORMATS.zh.md)。

## 参考

- Android Update Engine 元数据格式：
  - <https://android.googlesource.com/platform/system/update_engine/+/master/update_metadata.proto>
- Go 语言的同类项目：
  - <https://github.com/ssut/payload-dumper-go>

## 致谢

感谢 [payload-dumper-go](https://github.com/ssut/payload-dumper-go) 项目在协议行为方面提供的参考。
