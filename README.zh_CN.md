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

安装下方列出的包后，如果链接时仍然提示缺少 `upb` 或 `utf8_range`，可以再手动编译安装这两个库。

#### Debian / Ubuntu

```bash
sudo apt update
sudo apt install -y protobuf-compiler libbz2-dev libupb-dev libgrpc-dev
```

> Debian 上 `libupb.so` 由 `libgrpc-dev` 提供

#### Fedora

```bash
sudo dnf install -y protobuf-compiler bzip2-devel grpc-devel
```

#### Arch Linux

```bash
sudo pacman -S --needed protobuf bzip2 grpc
```

> Arch 的 `grpc` 包包含 `libupb.so`，`upb` 和 `utf8_range` 没有单独官方的包

#### Gentoo

```bash
sudo emerge --ask dev-libs/protobuf app-arch/bzip2 net-libs/grpc
```

> Gentoo 的 `dev-libs/protobuf` 有 `libupb` USE 标志。如果你的系统配置没有编译出可链接的 `upb`/`utf8_range`，
> 需要先手动安装再执行 `zig build`

## 编译

```bash
zig build
```

编译完成后，可通过 `zig build run -- ...` 直接运行，或从安装前缀的 `bin/zpayload-dumper` 调用。

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
```

### 选项

| 选项 | 说明 |
|------|------|
| `-h`, `--help` | 显示完整帮助并退出 |
| `-v`, `--version` | 显示版本号并退出 |
| `-l`, `--list` | 列出所有分区后退出 |
| `-p`, `--partitions <csv>` | 只提取指定的分区（用逗号分隔） |
| `-o`, `--output <dir>` | 输出目录（默认：`extracted_YYYYMMDD_HHMMSS`） |
| `-c`, `--concurrency <n>` | 并行工作线程数（默认：`nproc / 2`，逻辑线程数的一半） |
| `--dry-run` | 模拟提取进度，不实际写入输出（用于测试进度 UI 或验证 payload 可解析性） |
| `--color` | 等价于 `--color=always` |
| `--color=<mode>` | 颜色模式：`auto`、`always`、`never` |
| `--no-color` | 等价于 `--color=never` |
| `--format=<mode>` | 输出格式：`text`、`json`（影响 `--version` 和 `--list` 输出） |

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
- `TMPDIR`

### 磁盘空间检查

提取开始前，程序会自动检查输出目录的可用磁盘空间。如果空间不足以容纳所选分区，会立即中止并提示需要多少空间、实际有多少可用空间。

### 进度显示

- **终端（TTY）：** 显示实时的多分区进度条
- **重定向/管道：** 输出简洁的单行日志
- **自动着色：** help 和 CLI 日志都会根据 `isTTY` 自动着色，也可以通过参数或环境变量覆盖

## 开发

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

完整提取 payload，并用 SHA-256 与预期输出对比：

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
（`scripts/generate_sample_payload.py --total-mb 128`），
包含 `REPLACE`、`REPLACE_XZ`、`REPLACE_BZ`、`ZSTD` 和 `ZERO` 五种操作类型。

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

用于本地测试或持续集成，可以生成合成 payload 和对应的预期输出：

```bash
# 小型样本（默认，约 56 KB payload）
python3 scripts/generate_sample_payload.py --name smoke1

# 大型样本，用于性能测试（约 80 MB payload，128 MB 原始数据）
python3 scripts/generate_sample_payload.py --name bench128 --total-mb 128
```

输出会放到 `tests/data/`（该目录被 git 忽略），然后可以验证：

```bash
zig build run -- -o tmp/smoke1_out tests/data/generated/smoke1/payload.bin
zig build run -- -o tmp/smoke1_zip_out tests/data/generated/smoke1/ota_update.zip
```

## 支持的 Payload 特性

- 格式：`CrAU` 文件头，版本 2
- 通过 `upb` 解析 protobuf 元数据
- 支持的操作类型：
  - `REPLACE` — 原始数据直接复制
  - `REPLACE_XZ` — XZ 压缩数据
  - `REPLACE_BZ` — Bzip2 压缩数据
  - `ZSTD` — Zstd 压缩数据
  - `ZERO` — 全零填充块
- 对操作数据进行 SHA-256 校验
- 输入支持：单独的 `payload.bin`，或包含 `payload.bin` 的 `.zip` 文件

## 参考

- Android Update Engine 元数据格式：
  - <https://android.googlesource.com/platform/system/update_engine/+/master/update_metadata.proto>
- Go 语言的同类项目：
  - <https://github.com/ssut/payload-dumper-go>

## 致谢

感谢 [payload-dumper-go](https://github.com/ssut/payload-dumper-go) 项目在协议行为方面提供的参考。
