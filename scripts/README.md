# payload-gen

A standalone Python toolkit for generating synthetic Android OTA `payload.bin` test samples.

It is useful for:

- Testing Android OTA payload dumpers / extractors
- Generating reproducible regression test fixtures
- CI pipelines that need valid and invalid payload samples
- Benchmarking extraction tools with controlled inputs

The tool is managed with [`uv`](https://docs.astral.sh/uv/) and can be used independently of any specific dumper implementation.

## Setup

Requirements:

- Python `3.13+`
- [`uv`](https://docs.astral.sh/uv/)
- `protoc`
- `zstd`

Install dependencies:

```bash
uv sync
```

## Usage

### `payload-gen sample`

Generates synthetic `payload.bin`, a simulated OTA zip, and matching expected output images.

```bash
uv run payload-gen sample --name smoke1 --out-root ./output
uv run payload-gen sample --name bench128 --total-mb 128 --out-root ./output
uv run payload-gen sample --name bad-magic --scenario invalid_magic --out-root ./output
```

Parameters:

- `--out-root`: output directory. Default: `./generated`
- `--name`: sample name
- `--seed`: fixed random seed for reproducible generation
- `--total-mb`: target raw partition size budget
- `--scenario`: sample type. Default: `valid`
- `--list-scenarios`: print supported scenarios and exit

Supported scenarios:

- `valid`: well-formed payload and OTA zip
- `invalid_magic`: corrupted payload header magic
- `unsupported_version`: payload version changed from `2` to `3`
- `truncated_payload`: payload truncated after metadata begins
- `checksum_mismatch`: corrupted blob without updating manifest hashes
- `invalid_partition_name`: unsafe partition name such as `../evil_boot`
- `missing_payload_in_zip`: zip without `payload.bin`
- `corrupt_zip_payload`: valid on-disk payload, corrupted copy inside zip

Output layout:

```text
<out-root>/<name>/
  payload.bin
  ota_update.zip
  manifest.textproto
  scenario.txt
  expected_result.txt
  extracted/
    *.img
```

### `payload-gen delta`

Generates a delta payload using a real `SOURCE_BSDIFF` operation.

```bash
uv run payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output ./output/test_delta.bin
```

Generate a complete test bundle:

```bash
uv run payload-gen delta \
  --old old_boot.img \
  --new new_boot.img \
  --partition-name boot \
  --output ./output/bsdiff-sample/payload.bin \
  --bundle-dir ./output/bsdiff-sample
```

Parameters:

- `--old`: source image for the `SOURCE_BSDIFF` operation
- `--new`: expected image after applying the patch
- `--partition-name`: manifest partition name. Default: `test`
- `--output`, `-o`: output `payload.bin` path
- `--bundle-dir`: optional test sample bundle directory
- `--block-size`: alignment block size. Default: `4096`
- `--proto-dir`: directory containing `update_metadata.proto`
- `--check-with`: optional dumper binary for quick `-l` validation

Bundle output layout:

```text
<bundle-dir>/
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

## TAR Input

The generator produces `.zip` OTA files by default. To test TAR input, manually create an archive:

```bash
cd ./output/smoke1
tar czf ota_update.tar.gz payload.bin
```

## Integration Example

If you are developing a payload dumper, you can use the generated samples for end-to-end validation:

```bash
# Generate a sample
uv run payload-gen sample --name smoke1 --out-root ./samples

# Validate with your dumper
your-dumper -l ./samples/smoke1/payload.bin
your-dumper -o ./samples/smoke1_out ./samples/smoke1/payload.bin
```

## Coverage

Currently supported:

- Normal `payload.bin` extraction samples
- OTA zip input
- Error cases for malformed payloads
- Path traversal and manifest validation
- Real `SOURCE_BSDIFF` with old/new image pairs

Not currently covered:

- Multi-partition delta payloads with mixed operations
- Payload signatures or signed metadata
- Production Android OTA metadata beyond what dumpers typically need
