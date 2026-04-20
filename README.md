# zpayload-dumper

[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org)

Zig implementation of Android `payload.bin` dumper.

> [!IMPORTANT]
> This project currently targets Zig `0.16.0` and the current codebase is organized around Zig 0.16 APIs.

## Install

Prerequisites:

- Zig `0.16.0` (install via your distro package manager or [ziglang.org](https://ziglang.org))
- `protoc` with `--upb_out` and `--upb_minitable_out` plugins
- System libs: `upb`, `utf8_range`, `lzma`, `bz2`, `zstd`

### Distro Support

| Distro | Package Manager | Status | Notes |
|--------|----------------|--------|-------|
| Arch Linux | `pacman` | ✅ Supported | `protobuf` ≥ 34 ships `protoc-gen-upb` |
| Gentoo | `emerge` | ✅ Supported | `dev-libs/protobuf[upb]` |
| Ubuntu | `apt` | ❌ Not supported | apt `protobuf-compiler` (3.21) lacks upb plugins |
| Debian | `apt` | ❌ Not supported | same as Ubuntu |
| Fedora | `dnf` | ❌ Not supported | dnf `protobuf-compiler` lacks upb plugins |
| Alpine | `apk` | ⚠️ Known issue | `protoc-gen-upb` present, but Zig/musl static-link order fails |

> **Why apt/dnf don't work:** The `protoc-gen-upb` and `protoc-gen-upb_minitable` plugins are only
> included in protobuf 30+. Ubuntu 24.04, Debian 12 and Fedora 41 still ship protobuf 3.21.x,
> whose `protoc` cannot generate upb C code.

### Install Dependencies (Arch / Gentoo)

#### Arch Linux

```bash
sudo pacman -S --needed protobuf xz bzip2 zstd
```

#### Gentoo

```bash
sudo emerge --ask dev-libs/protobuf app-arch/xz-utils app-arch/bzip2 app-arch/zstd
```

### Building protobuf from source (Ubuntu / Debian / Fedora)

If your distro does not provide a recent enough `protoc` with upb plugins, build protobuf from source:

```bash
# 1. Install build dependencies
# Ubuntu/Debian:
sudo apt install -y cmake g++ git liblzma-dev libbz2-dev libzstd-dev
# Fedora:
sudo dnf install -y cmake gcc-c++ git xz-devel bzip2-devel libzstd-devel

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

### Alpine Linux known issue

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

## Usage

```bash
./zig-out/bin/zpayload-dumper [options] /path/to/payload.bin
```

Options:

- `-l`, `--list`: list partitions only
- `-p`, `--partitions <csv>`: extract selected partitions
- `-o`, `--output <dir>`: output directory
- `-c`, `--concurrency <n>`: number of parallel partition workers, default `4`
- `--color`: alias for `--color=always`
- `--color=<mode>`: color mode, one of `auto`, `always`, `never`
- `--no-color`: alias for `--color=never`

If `-o` is omitted, the default output directory is generated as local time:
`extracted_YYYYMMDD_HHMMSS`.

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
- `TMPDIR`

Disk space check:

Before extraction begins, the engine checks available disk space via `statvfs`. If the output directory does not have enough free
space for the selected partitions, extraction aborts immediately with a clear error message showing required vs available space.

Examples:

```bash
./zig-out/bin/zpayload-dumper -l payload.bin
./zig-out/bin/zpayload-dumper -p boot,vendor -o out payload.bin
./zig-out/bin/zpayload-dumper payload.zip
```

Progress:

- TTY: dynamic multi-partition progress view
- non-TTY: concise line-based logs
- color auto mode is resolved per output stream using `isTTY`

## Test And Bench

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

End-to-end regression check (extract + hash-compare with generated baseline):

```bash
zig build check_e2e
```

Lightweight benchmark smoke (fixed partition subset):

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

- Payload header parse: `CrAU`, version `2`, manifest/signature lengths.
- Protobuf decode via `upb` (`DeltaArchiveManifest`, `Signatures`).
- Operations:
  - `REPLACE`
  - `REPLACE_XZ`
  - `REPLACE_BZ`
  - `ZSTD`
  - `ZERO`
- SHA-256 verification for operation data blobs.
- Input:
  - raw `payload.bin`
  - `.zip` containing `payload.bin`

## Synthetic Sample Generator

Generate a tiny synthetic `payload.bin`, a simulated OTA zip (`ota_update.zip`),
and matching golden extracted images
for local/CI testing (output is under `tests/data/`, which is git-ignored):

```bash
python3 scripts/generate_sample_payload.py --name smoke1
```

Then verify with the dumper:

```bash
./zig-out/bin/zpayload-dumper -o .zig-cache/smoke1_out /path/to/payload.bin
./zig-out/bin/zpayload-dumper -o .zig-cache/smoke1_zip_out /path/to/ota_update.zip
```

## References

- Android Update Engine metadata proto:
  - <https://android.googlesource.com/platform/system/update_engine/+/master/update_metadata.proto>
- payload-dumper-go:
  - <https://github.com/ssut/payload-dumper-go>

## Thanks

- Thanks to the `payload-dumper-go` project for protocol behavior reference:
  <https://github.com/ssut/payload-dumper-go>
