# Odd OTA Formats — Vendor Compatibility Notes

> This document tracks non-standard Android OTA formats reported by the
> community (XDA, GitHub issues, vendor forums) and records what
> `zpayload-dumper` currently handles, what it does not, and why.

---

## Background

Google’s A/B (seamless) update system, introduced in Android Oreo, uses a single `payload.bin` file inside a ZIP package. The
format is defined by the ChromeOS update engine and follows a strict header → manifest → signatures → data blob layout.

However, several OEMs have deviated from this standard—either inside the payload itself (new `InstallOperation` types) or in the
outer packaging (encrypted ZIPs, alternate archive formats). This document catalogs those deviations as they relate to extraction
tools like `zpayload-dumper`.

---

## 1. BBK Electronics (vivo / OPPO / realme / OnePlus)

### What changed

Since early 2024, firmware from BBK-owned brands began using **Zstandard (zstd)** compression for data blobs inside `payload.bin`.
This corresponds to a new `InstallOperation` enum value:

```protobuf
ZSTD = 14;
```

Older versions of `payload-dumper-go` and the original Python `payload_dumper` would either crash or emit zero-byte images because
the decompressor did not recognize type `14`.

### Community references

- payload-dumper-go PR [#51](https://github.com/ssut/payload-dumper-go/pull/51) — "Add vivo payload support" (merged Oct 2024)
- payload-dumper-go issue [#56](https://github.com/ssut/payload-dumper-go/issues/56) — OxygenOS 15 / Android 15 compatibility
- XDA threads reporting "0 KB output" or "input format not supported" on OnePlus 11/12 firmware

### Project status

| Aspect | Status |
|--------|--------|
| `ZSTD = 14` in proto | ✅ Present in `proto/update_metadata.proto` |
| `ZSTD = 14` in Zig enum | ✅ Present in `src/ffi/upb.zig` |
| Decompressor | ✅ `decompressZstdToWriter` in `src/compress/root.zig` |
| Engine dispatch | ✅ Handled in `src/payload/engine.zig` |

**Verdict:** Fully supported.

---

## 2. OPPO / realme — OZIP Encryption

### What changed

OPPO and realme ship OTA files with the `.ozip` extension. These are **AES-ECB encrypted ZIP archives**, not plain ZIP files. The
file header starts with `OPPOENCRYPT!`. Each device family uses a hard-coded AES key; community tools like `ozipdecrypt.py`
maintain a key database.

This is **not** a payload.bin format deviation—it happens one layer *above* payload.bin. You must decrypt the OZIP to a normal ZIP
first, then extract `payload.bin`.

### Community references

- XDA guide: "How to Extract Fastboot Images from .ozip File"
- `ozipdecrypt.py` by B. Kerler (MIT license)

### Project status

| Aspect | Status |
|--------|--------|
| OZIP decryption | ❌ Out of scope |
| Plain payload.bin after decryption | ✅ Supported (same as any standard payload) |

**Verdict:** Will not handle `.ozip` files directly. Users must decrypt externally.

---

## 3. Samsung

### What changed

Samsung does **not** use `payload.bin` at all. Their firmware is distributed as:

- **tar.md5** archives (AP, BL, CP, CSC, etc.)
- Flashed via Odin or Heimdall

This is an entirely different ecosystem. No `payload.bin` exists to dump.

### Project status

| Aspect | Status |
|--------|--------|
| tar.md5 parsing | ❌ Out of scope |

**Verdict:** Not applicable.

---

## 4. Huawei (and former Honor)

### What changed

Huawei uses the **UPDATE.APP** format, which is proprietary and unrelated to the ChromeOS update engine. It is processed by
Huawei’s own `update_engine` binary.

### Project status

| Aspect | Status |
|--------|--------|
| UPDATE.APP parsing | ❌ Out of scope |

**Verdict:** Not applicable.

---

## 5. Xiaomi / Redmi / POCO

### What changed

Xiaomi distributes firmware as **TGZ / TAR** archives. After unpacking, you typically obtain a standard `payload.bin` inside a
plain ZIP. The payload itself is usually well-formed.

### Project status

| Aspect | Status |
|--------|--------|
| TGZ/TAR unpacking | ❌ Out of scope (use `tar` or `7z`) |
| payload.bin extraction | ✅ Supported |

**Verdict:** Standard payload; only the outer packaging differs.

---

## 6. Motorola

### What changed

Some Motorola firmware uses **sparsechunk** files instead of `payload.bin`. This is a sparse ext4 image split into chunks for
flashing.

### Project status

| Aspect | Status |
|--------|--------|
| sparsechunk handling | ❌ Out of scope |

**Verdict:** Not applicable.

---

## 7. Sony

### What changed

Sony historically uses **FTF** (Flash Tool Firmware) format, handled by Flashtool / NewFlasher. Modern Sony devices with A/B
partitioning may use standard payload.bin, but the traditional distribution path is FTF.

### Project status

| Aspect | Status |
|--------|--------|
| FTF parsing | ❌ Out of scope |

**Verdict:** Not applicable.

---

## 8. Incremental / Delta OTA

### What changed

Incremental (delta) OTAs contain operations that reference the **current on-device partition** as a source:

- `SOURCE_COPY = 4` — copy extents from the old partition image unchanged
- `SOURCE_BSDIFF = 5` — apply a bsdiff patch against the old partition data
- `BSDIFF = 3` (deprecated, not present in modern payloads)
- `MOVE = 2` (deprecated, not present in modern payloads)

Applying these requires the original partition image. The tool must be given a directory containing the old partition images so it can read source extents and reconstruct the final image.

### Community references

- payload-dumper-go issue [#26](https://github.com/ssut/payload-dumper-go/issues/26)
- XDA threads noting "Diff suggests it's an incremental OTA zip, which isn't supported."

### Project status

| Aspect | Status | Notes |
|--------|--------|-------|
| Full (non-incremental) OTA | ✅ Supported | |
| `SOURCE_COPY` | ✅ Supported | Requires `--old <dir>` |
| `SOURCE_BSDIFF` | ✅ Supported | Requires `--old <dir>` **and** compiling with `-Dbsdiff` |
| Other delta ops (`PUFFDIFF`, `BROTLI_BSDIFF`, `ZUCCHINI`, `LZ4DIFF_*`) | ❌ Not supported | See section 9 |

**Verdict:** Supported for the two most common delta operations. Provide the old image directory via `--old` and build with `-Dbsdiff` if the payload uses `SOURCE_BSDIFF`.

---

## 9. Proto-Defined but Not Yet Implemented Operations

The following `InstallOperation.Type` values are already present in `proto/update_metadata.proto` and `src/ffi/upb.zig`, but
**lack decompression / application logic** in the engine:

| Type | Value | Compression / Format | Status |
|------|-------|---------------------|--------|
| `PUFFDIFF` | 9 | Puff diff | ❌ Not implemented |
| `BROTLI_BSDIFF` | 10 | Brotli + bsdiff | ❌ Not implemented |
| `ZUCCHINI` | 11 | Zucchini | ❌ Not implemented |
| `LZ4DIFF_BSDIFF` | 12 | LZ4 diff + bsdiff | ❌ Not implemented |
| `LZ4DIFF_PUFFDIFF` | 13 | LZ4 diff + puffdiff | ❌ Not implemented |

If a future firmware (e.g., a Pixel device adopting `BROTLI_BSDIFF`) uses any of these, the engine will return
`error.UnsupportedOperation`.

---

## Summary Matrix

| Vendor / Format | Outer Layer | payload.bin quirks | Supported? |
|-----------------|-------------|-------------------|------------|
| Google Pixel | Plain ZIP | Standard | ✅ |
| vivo | Plain ZIP | ZSTD = 14 | ✅ |
| OnePlus | Plain ZIP | ZSTD = 14 | ✅ |
| OPPO / realme | **OZIP encrypted** | Standard after decrypt | ❌ (outer layer) |
| Samsung | **tar.md5** | N/A | ❌ |
| Huawei | **UPDATE.APP** | N/A | ❌ |
| Xiaomi | **TGZ/TAR** | Usually standard | ✅ (extracts payload.bin from tar/tar.gz/tgz) |
| Motorola | **sparsechunk** | N/A | ❌ |
| Sony | **FTF** | N/A | ❌ |
| Delta OTA | Plain ZIP | `SOURCE_COPY`, `SOURCE_BSDIFF` | ✅ (with `--old` dir; `SOURCE_BSDIFF` needs `-Dbsdiff`)

---

## What This Means for the Project

1. **The most common "odd" case we actually face** is BBK’s adoption of `ZSTD = 14`. That is already handled.
2. **The next likely gap** is Google or another vendor enabling `BROTLI_BSDIFF = 10`. Adding a Brotli decompressor (or linking
`brotli`) would be the fix.
3. **Everything else** (OZIP, tar.md5, UPDATE.APP, sparsechunk, FTF) is outside the scope of a `payload.bin` dumper. We should
document this clearly so users do not file false-positive bug reports.
4. **Delta OTA** is supported for `SOURCE_COPY` and `SOURCE_BSDIFF` when the old partition images are provided via `--old`. Full extraction of a delta payload is possible as long as the source images are available. More exotic delta formats (`PUFFDIFF`, `BROTLI_BSDIFF`, etc.) remain unsupported.
