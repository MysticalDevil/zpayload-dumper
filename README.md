# zpayload-dumper

Zig implementation of Android `payload.bin` dumper.

## IMPORTANT

- This project currently targets Zig `0.16-dev` (`master`) only.

## Goals

- Protocol-compatible with `payload-dumper-go` for supported operations.
- Keep implementation independent from `payload-dumper-go` source tree.
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

Build:

```bash
zig build
```

Tests:

```bash
zig build test
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
- `payload-dumper-go` is reference-only and ignored from git tracking.
