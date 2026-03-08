# zpayload-dumper

Zig implementation of Android `payload.bin` dumper.

## IMPORTANT

- This project currently targets Zig `0.16-dev` (`master`) only.

## Goals

- Protocol-compatible with the Android OTA payload format for supported operations.
- Keep implementation independent from external reference source trees.
- Prefer mature libraries for critical protocol/codec pieces.

## Current support

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

## Build

Prerequisites:

- Zig `master` (tracking 0.16 APIs)
- `protoc` with `--upb_out` and `--upb_minitable_out`
- System libs: `upb`, `utf8_range`, `lzma`, `bz2`, `zstd`

### Install Dependencies (by distro)

The package names below are checked against official distro package indexes (as of 2026-03-08).
If your linker still reports missing `upb`/`utf8_range` symbols, install or build those libraries manually.

#### Debian

```bash
sudo apt update
sudo apt install -y protobuf-compiler liblzma-dev libbz2-dev libzstd-dev libupb-dev libgrpc-dev
```

`libgrpc-dev` is included because it provides `libupb.so` in Debian package contents.

#### Fedora

```bash
sudo dnf install -y protobuf-compiler xz-devel bzip2-devel libzstd-devel grpc-devel
```

#### Arch Linux

```bash
sudo pacman -S --needed protobuf xz bzip2 zstd grpc
```

Arch `grpc` package provides `libupb.so`; `upb`/`utf8_range` are not exposed as separate official packages.

#### Gentoo

```bash
sudo emerge --ask dev-libs/protobuf app-arch/xz-utils app-arch/bzip2 app-arch/zstd net-libs/grpc
```

Gentoo `dev-libs/protobuf` includes `libupb` USE support; if your profile/package config does not
provide linkable `upb`/`utf8_range`, install/build them manually before `zig build`.

Build:

```bash
zig build
```

Tests:

```bash
zig build test
```

Stress tests:

```bash
zig build test-stress
```

End-to-end regression check (extract + hash-compare with generated baseline):

```bash
zig build check-e2e
```

Lightweight benchmark smoke (fixed partition subset):

```bash
zig build bench-smoke
```

Custom payload:

```bash
zig build bench-smoke -- /path/to/payload.bin
```

## Usage

```bash
./zig-out/bin/zpayload-dumper [options] /path/to/payload.bin
```

Options:

- `-l`, `--list`: list partitions only
- `-p`, `--partitions <csv>`: extract selected partitions
- `-o`, `--output <dir>`: output directory
- `-c`, `--concurrency <n>`: number of parallel partition workers

If `-o` is omitted, the default output directory is generated as local time:
`extracted_YYYYMMDD_HHMMSS`.

Progress:

- TTY: dynamic multi-partition progress view
- non-TTY: concise line-based logs

Examples:

```bash
./zig-out/bin/zpayload-dumper -l payload.bin
./zig-out/bin/zpayload-dumper -p boot,vendor -o out payload.bin
./zig-out/bin/zpayload-dumper payload.zip
```

## Notes

- `proto/update_metadata.proto` is the local protocol source used by this project.

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
  - https://android.googlesource.com/platform/system/update_engine/+/master/update_metadata.proto
- payload-dumper-go:
  - https://github.com/ssut/payload-dumper-go

## Thanks

- Thanks to the `payload-dumper-go` project for protocol behavior reference:
  https://github.com/ssut/payload-dumper-go
