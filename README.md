# zpayload-dumper

[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org)

Zig implementation of Android `payload.bin` dumper.

## Install

Prerequisites:

- Zig `0.16.0` (install via your distro package manager or [ziglang.org](https://ziglang.org))
- `protoc` with `--upb_out` and `--upb_minitable_out` plugins
- System libs: `upb`, `utf8_range`, `bz2`
  - XZ and Zstd use Zig's native `std.compress` (no system libs needed)
  - Only bzip2 still requires `libbz2.so`

### Distro Support

| Distro | Package Manager | Status | Notes |
|--------|----------------|--------|-------|
| Arch Linux | `pacman` | ✅ Supported | `protobuf` ≥ 34 ships `protoc-gen-upb` |
| Gentoo | `emerge` | ✅ Supported | `dev-libs/protobuf[upb]` |
| Ubuntu | `apt` | ⚠️ Build from source | apt `protobuf-compiler` (3.21) lacks upb plugins |
| Debian | `apt` | ⚠️ Build from source | same as Ubuntu |
| Fedora | `dnf` | ⚠️ Build from source | dnf `protobuf-compiler` lacks upb plugins |
| Alpine | `apk` | ⚠️ Known issue | `protoc-gen-upb` present, but Zig/musl static-link order fails |

> **Why apt/dnf need source build:** The `protoc-gen-upb` and `protoc-gen-upb_minitable` plugins are only
> included in protobuf 30+. Ubuntu 24.04, Debian 12 and Fedora 41 still ship protobuf 3.21.x,
> whose `protoc` cannot generate upb C code.

### Install Dependencies

#### Arch Linux

```bash
sudo pacman -S --needed protobuf bzip2
```

#### Gentoo

```bash
sudo emerge --ask dev-libs/protobuf app-arch/bzip2
```

#### Ubuntu / Debian / Fedora

Build protobuf from source:

```bash
# 1. Install build dependencies
# Ubuntu/Debian:
sudo apt install -y cmake g++ git libbz2-dev
# Fedora:
sudo dnf install -y cmake gcc-c++ git bzip2-devel

# 2. Build & install protobuf (includes protoc + libupb + upb generators)
git clone https://github.com/protocolbuffers/protobuf.git
cd protobuf
git checkout v34.1   # or newer
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -Dprotobuf_BUILD_TESTS=OFF \
  -Dprotobuf_BUILD_SHARED_LIBS=ON \
  -Dprotobuf_BUILD_UPB=ON
cmake --build build -j$(nproc)
sudo cmake --install build

# 3. Build zpayload-dumper
cd /path/to/zpayload-dumper
zig build
```

#### Alpine Linux

Alpine's `protobuf` package (31.1+) includes `protoc-gen-upb`, but `upb` is provided only as a
static archive (`libupb.a`). Zig's linker on musl targets places static libraries before object
files, causing undefined-symbol errors for `upb_Arena_Free`, `upb_Decode`, etc. There is currently
no straightforward workaround; use a glibc-based distro (Arch, Gentoo, Ubuntu/Debian/Fedora with
source-built protobuf) instead.

### Docker build (any OS)

If your distro is not supported, use the provided Docker image:

```bash
docker compose run --rm builder
```

Or with plain Docker:

```bash
docker build -t zpayload-builder .
docker run --rm -v .:/src zpayload-builder
```

## Build

```bash
zig build
```

### Delta Payload Support (Optional)

To enable `SOURCE_BSDIFF` delta operations, build with the `-Dbsdiff` flag:

```bash
zig build -Dbsdiff
```

`SOURCE_COPY` delta operations are always enabled and do not require extra flags.

### Cross-Architecture Release Builds

#### Release Build via Docker

`scripts/build-release.sh` uses `Dockerfile` to build a release binary for the **current host architecture**.
Protobuf is compiled from source inside the container, and the correct Zig binary is downloaded
automatically for amd64 or arm64.

```bash
just release
# or directly:
./scripts/build-release.sh
```

The artifact is placed in `release/` with `SHA256SUMS`.

> **Platform support:** The `main` branch targets Linux. Windows cross-compilation and native builds are maintained on the [`feat/windows-support`](../../tree/feat/windows-support) branch.
>
> **Async experiment:** The [`feat/async-engine`](../../tree/feat/async-engine) branch replaces the manual thread pool with `std.Io.Group.concurrent` and is ready for `std.Io.Uring` (io_uring) once upstream stabilizes the runtime. Zig 0.16.0's `std.Io.Uring` requires compile-fix [PR #31764](https://codeberg.org/ziglang/zig/pulls/31764) (`ReadOnlyFileSystem` missing from `Dir.OpenError` / `Dir.RealPathFileError`) and still segfaults at runtime in `CancelRegion.init` during fiber context switches, so the backend remains disabled on that branch.
>
> **libxev experiment:** The [`feat/libxev-engine`](../../tree/feat/libxev-engine) branch replaces the manual thread pool with [mitchellh/libxev](https://github.com/mitchellh/libxev) `ThreadPool`. It compiles and passes all tests, but shows no performance improvement over manual threads on this CPU-bound workload (within measurement noise). The dependency is integrated via `build.zig.zon`.

## Usage

```bash
zig build run -- [options] /path/to/payload.bin
```

Options:

- `-h`, `--help`: show full help and exit
- `-v`, `--version`: show version and exit
- `-l`, `--list`: list partitions only
- `-p`, `--partitions <csv>`: extract selected partitions
- `-o`, `--output <dir>`: output directory
- `-c`, `--concurrency <n>`: number of parallel partition workers, default is half of logical CPU threads (`nproc / 2`)
- `--old <dir>`: directory containing source partition images for delta payload extraction
- `--dry-run`: simulate extraction progress without writing output (useful for testing progress UI or validating payload parseability)
- `--color`: alias for `--color=always`
- `--color=<mode>`: color mode, one of `auto`, `always`, `never`
- `--no-color`: alias for `--color=never`
- `--format <mode>`: output format, one of `text`, `json` (affects `--version` and `--list` output)
- `--format=json`: shorthand for JSON output

If `-o` is omitted, the default output directory is generated as local time:
`extracted_YYYYMMDD_HHMMSS`.

Error handling:

- Unsupported arguments or missing input print a brief colored usage message and exit with code `2`.
- `--help` and `--version` exit with code `0`.

Color precedence:

- command-line flags
- `ZPAYLOAD_COLOR`
- `CLICOLOR_FORCE`, `NO_COLOR`, `CLICOLOR`
- automatic `isTTY` detection

Environment variables:

- `ZPAYLOAD_COLOR=auto|always|never`
- `NO_COLOR`
- `CLICOLOR=0`
- `CLICOLOR_FORCE=1`

Temp directory:

When processing `.zip` or `.tar`/`.tar.gz`/`.tgz` input, the tool extracts `payload.bin` to a temporary directory
under `./.tmp` in the current working directory. The temp directory is automatically created and removed after extraction completes.

Disk space check:

Before extraction begins, the tool checks available disk space in the output directory. If there is not enough free
space for the selected partitions, extraction aborts immediately with a clear error message showing required vs available space.

Examples:

```bash
zig build run -- -l payload.bin
zig build run -- -p boot,vendor -o out payload.bin
zig build run -- payload.zip
zig build run -- --dry-run -p boot,vendor payload.bin
zig build run -- --dry-run payload.zip

# Delta payload extraction (requires source images)
zig build run -- --old old_images/ -o new_images/ incremental_payload.bin
zig build run -- --old old_images/ -p boot,vendor -o new_images/ incremental_payload.bin
```

Progress:

- TTY: dynamic multi-partition progress view
- non-TTY: concise line-based logs
- color auto mode is resolved per output stream using `isTTY`

## Test And Bench

Python helper tooling lives under `scripts/` as a standard `uv`-managed project.
Use `uv run --project scripts payload-gen ...` as the primary entrypoint for test sample generation and Python helper commands.
Detailed generator documentation lives in [`scripts/README.md`](scripts/README.md).

Tests:

```bash
zig build test
```

Stress tests:

```bash
zig build test_stress
```

`test_stress` now includes:

- full extraction baseline check
- selected partition concurrency matrix (`1/2/4/8`, repeated rounds)
- repeated full extraction stability rounds

End-to-end test (extract and compare hashes against expected output):

```bash
zig build check_e2e
```

Quick health-check benchmark (fixed partition subset):

```bash
zig build bench_smoke
```

Custom payload:

```bash
zig build bench_smoke -- /path/to/payload.bin
```

Pressure benchmark matrix (startup/system partition sets with `1/2/4/8` concurrency):

```bash
zig build bench_pressure
zig build bench_pressure -- /path/to/payload.bin
```

## Current Support

- Payload header parsing: `CrAU`, version `2`, manifest/signature lengths.
- Protobuf decode via `upb` (`DeltaArchiveManifest`, `Signatures`).
- Operations:
  - `REPLACE`
  - `REPLACE_XZ`
  - `REPLACE_BZ`
  - `ZSTD`
  - `ZERO`
- `SOURCE_COPY` (delta — requires `--old`)
- `SOURCE_BSDIFF` (delta — requires `--old` and `-Dbsdiff`)
- SHA-256 verification for operation data
- Source image SHA-256 verification for delta operations (`src_sha256_hash`)
- Input:
  - raw `payload.bin`
  - `.zip` containing `payload.bin`
  - `.tar`/`.tar.gz`/`.tgz` containing `payload.bin`
- Disk space pre-check before extraction
- Colored output with automatic TTY detection

> See [`docs/ODD_OTA_FORMATS.md`](docs/ODD_OTA_FORMATS.md) for a vendor-by-vendor breakdown
> of non-standard OTA formats (vivo, OPPO, Samsung, Huawei, Xiaomi, Motorola, Sony)
> and what this project does / does not handle.

## Benchmark vs payload-dumper-go

All numbers below are actual runtime (mean of 5 runs, hyperfine).

**Test machine:** AMD Ryzen 7 4800H (8c/16t), 22 GB DDR4, ZHITAI TiPlus7100 1TB NVMe,
Gentoo Linux (kernel 7.0.0-gentoo-dist).

The test payload is a **78 MB** synthetic sample
(`uv run --project scripts payload-gen sample --total-mb 128`) that covers
`REPLACE`, `REPLACE_XZ`, `REPLACE_BZ`, `ZSTD` and `ZERO` operations.

| Scenario | Concurrency | zpayload-dumper | payload-dumper-go | Speed-up |
|----------|-------------|-----------------|-------------------|----------|
| `payload.bin` | 1 worker | **1 137 ms** | 1 378 ms | **1.21×** |
| `payload.bin` | 4 workers | **409 ms** | 467 ms | **1.14×** |
| `payload.bin` | 8 workers | 308 ms | **295 ms** | 0.96× |
| `ota_update.zip` | 4 workers | 625 ms | **523 ms** | 0.8× |

Observations:

- **Compress engine refactor**: XZ and Zstd decompression were migrated from
  C FFI (`liblzma`, `libzstd`) to Zig standard library (`std.compress.xz`,
  `std.compress.zstd`). This eliminated two system dependencies and improved
  single-threaded throughput by ~25%.
- **Single-threaded lead**: Zig wins at `c=1` across all payload sizes
  (1.12–1.42×). On larger payloads (`bench256`, `bench512`), the gap
  essentially disappears at `c=2–16` (within ±4%).
- **Go's scheduler wins on tiny workloads at high concurrency**: `bench32`
  at `c≥4` shows Go pulling ahead (up to 1.31× at `c=16`), where goroutine
  context-switch overhead is lower than Zig's thread pool + mutex.
- **Zip input**: Zip extraction remains slower than raw `payload.bin` for both
  tools, and the Go implementation currently leads there as well.

> See [`docs/COMPARISON.md`](docs/COMPARISON.md) for the full benchmark matrix
> (bench32/128/256/512, scaling across different thread counts, and performance analysis).

## Synthetic Sample Generator

Generate a synthetic `payload.bin`, a simulated OTA zip (`ota_update.zip`),
and matching expected output images
for local/CI testing (output is under `tests/data/`, which is git-ignored):

```bash
uv sync --project scripts

# tiny sample (~56 KB payload, default)
uv run --project scripts payload-gen sample --name smoke1

# larger sample for benchmarking (~80 MB payload with 128 MB raw data)
uv run --project scripts payload-gen sample --name bench128 --total-mb 128

# error test cases
uv run --project scripts payload-gen sample --name bad-magic --scenario invalid_magic
uv run --project scripts payload-gen sample --name fixture-matrix --scenario all --total-mb 32
```

Then verify with the dumper:

```bash
zig build run -- -o tmp/smoke1_out /path/to/payload.bin
zig build run -- -o tmp/smoke1_zip_out /path/to/ota_update.zip
```

List available sample scenarios:

```bash
uv run --project scripts payload-gen sample --list-scenarios
```

Generate a `SOURCE_BSDIFF` delta payload:

```bash
uv run --project scripts payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output test_payload.bin
```

Generate a complete test sample bundle for full pipeline testing:

```bash
uv run --project scripts payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output tests/data/generated/bsdiff-sample/payload.bin \
  --bundle-dir tests/data/generated/bsdiff-sample
```

The bundle includes `payload.bin`, `ota_update.zip`, `old/boot.img`,
`extracted/boot.img`, and `manifest.textproto`. The generated manifest
includes both `data_sha256_hash` and `src_sha256_hash`, so it validates
the real `SOURCE_BSDIFF` checksum path.

## References

- Android Update Engine metadata proto:
  - <https://android.googlesource.com/platform/system/update_engine/+/master/update_metadata.proto>
- payload-dumper-go:
  - <https://github.com/ssut/payload-dumper-go>

## Thanks

- Thanks to the `payload-dumper-go` project for protocol behavior reference:
  <https://github.com/ssut/payload-dumper-go>
