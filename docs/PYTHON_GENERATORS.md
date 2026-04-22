# Python Generators

This repository ships a small `uv`-managed Python project under [`scripts/`](../scripts/).
It is used to generate synthetic fixtures for local testing, CI, and regression work.

## Setup

Requirements:

- Python `3.13+`
- [`uv`](https://docs.astral.sh/uv/)
- `protoc`
- `zstd`

Install and sync the helper environment:

```bash
uv sync --project scripts
```

List available entrypoints:

```bash
uv run --project scripts payload-gen --help
```

Recommended top-level entrypoint:

```bash
uv run --project scripts payload-gen sample --name smoke1
uv run --project scripts payload-gen delta --old old.img --new new.img --output /tmp/test_delta.bin
```

## Entrypoints

### `payload-gen sample`

Generates synthetic `payload.bin` fixtures, simulated OTA zips, and matching golden extracted images.

Typical usage:

```bash
uv run --project scripts payload-gen sample --name smoke1
uv run --project scripts payload-gen sample --name bench128 --total-mb 128
uv run --project scripts payload-gen sample --name bad-magic --scenario invalid_magic
uv run --project scripts payload-gen sample --name matrix --scenario all --total-mb 32
```

Parameters:

- `--out-root`: output root relative to the repository root. Default: `tests/data/generated`
- `--name`: sample name. When `--scenario all` is used, the script expands this into `<name>-<scenario>`
- `--seed`: fixed random seed for reproducible fixture generation
- `--total-mb`: target raw partition size budget used to size the synthetic partitions
- `--scenario`: fixture type to generate. Default: `valid`
- `--list-scenarios`: print supported scenarios and exit

Supported scenarios:

- `valid`: well-formed payload and OTA zip
- `invalid_magic`: payload header magic is corrupted
- `unsupported_version`: payload header version is changed from `2` to `3`
- `truncated_payload`: payload file is truncated after metadata/data begins
- `checksum_mismatch`: one operation blob byte is corrupted without updating manifest hashes
- `invalid_partition_name`: manifest contains an unsafe partition name such as `../evil_boot`
- `missing_payload_in_zip`: OTA zip is valid but does not contain `payload.bin`
- `corrupt_zip_payload`: on-disk `payload.bin` stays valid, but the copy embedded in `ota_update.zip` is corrupted

Output layout:

```text
tests/data/generated/<name>/
  payload.bin
  ota_update.zip
  manifest.textproto
  scenario.txt
  expected_result.txt
  extracted/
    *.img
```

Notes:

- `expected_result.txt` is intended for Zig-side regression tests
- `scenario.txt` records scenario name, description, seed, and any scenario-specific notes
- the generator intentionally produces both success fixtures and negative fixtures

### `payload-gen delta`

Generates a synthetic delta payload using a real `SOURCE_BSDIFF` operation.

Typical usage:

```bash
uv run --project scripts payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output /tmp/test_delta.bin
```

To generate a complete fixture bundle:

```bash
uv run --project scripts payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output tests/data/generated/bsdiff-fixture/payload.bin \
  --bundle-dir tests/data/generated/bsdiff-fixture
```

Parameters:

- `--old`: source image used by the `SOURCE_BSDIFF` operation
- `--new`: expected extracted image after applying the patch
- `--partition-name`: manifest partition name. Default: `test`
- `--output`, `-o`: output `payload.bin` path
- `--bundle-dir`: optional fixture bundle directory
- `--block-size`: block size used for alignment and manifest extents. Default: `4096`
- `--proto-dir`: directory containing `update_metadata.proto`
- `--check-with`: optional `zpayload-dumper` binary used for a quick `-l` sanity check

Output layout when `--bundle-dir` is used:

```text
tests/data/generated/bsdiff-fixture/
  payload.bin
  ota_update.zip
  manifest.textproto
  scenario.txt
  expected_result.txt
  old/
    <partition>.img
  extracted/
    <partition>.img
```

Supported capability:

- real `SOURCE_BSDIFF` operation generation using `bsdiff4`
- block-aligned old/new image handling
- generated manifest includes:
  - `data_sha256_hash`
  - `src_sha256_hash`
- optional bundle output for end-to-end extraction tests

## What The Generators Cover

The Python project is intended to support these Zig-side test categories:

- normal extraction of synthetic `payload.bin`
- OTA zip input handling
- error classification for corrupted or malformed payloads
- path traversal and manifest validation regressions
- `SOURCE_BSDIFF` extraction with real old/new image pairs

It does not currently try to model:

- multi-partition delta payloads with mixed operation types in one fixture
- payload signatures or signed metadata blocks
- Android production OTA metadata beyond what the dumper currently needs

## Recommended Workflows

Generate a normal sample and verify it:

```bash
uv run --project scripts payload-gen sample --name smoke1
zig build check_e2e -- tests/data/generated/smoke1/payload.bin tests/data/generated/smoke1/extracted
```

Generate a negative fixture and verify the expected failure:

```bash
uv run --project scripts payload-gen sample --name bad-magic --scenario invalid_magic
zig build run -- tests/data/generated/bad-magic/payload.bin
```

Generate and extract a real `SOURCE_BSDIFF` fixture:

```bash
uv run --project scripts payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output /tmp/bsdiff-fixture/payload.bin \
  --bundle-dir /tmp/bsdiff-fixture

zig build run -Dbsdiff -- /tmp/bsdiff-fixture/payload.bin \
  --old /tmp/bsdiff-fixture/old \
  -o /tmp/bsdiff-fixture/out
```
