#!/usr/bin/env python3
"""
Generate a synthetic Android payload.bin and matching extracted images.

Usage:
  python3 scripts/generate_sample_payload.py
  python3 scripts/generate_sample_payload.py --out-root tests/data/generated --name demo --total-mb 128
"""

from __future__ import annotations

import argparse
import base64
import bz2
import hashlib
import lzma
import os
import random
import shutil
import struct
import subprocess
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple

BLOCK_SIZE = 4096
ALL_PARTITIONS = [
    "abl", "bl31", "gsa", "modem", "pvmfw", "system", "vbmeta_system",
    "vendor_dlkm", "bl1", "boot", "init_boot", "pbl", "system_dlkm",
    "tzsw", "vbmeta_vendor", "vendor", "bl2", "dtbo", "ldfw", "product",
    "system_ext", "vbmeta", "vendor_boot", "vendor_kernel_boot",
]

# Fixed "special" partitions that exercise specific code paths.
SPECIAL_PARTITIONS = {"boot", "vendor_boot", "system_ext", "product", "vbmeta"}


def zstd_compress(raw: bytes) -> bytes:
    proc = subprocess.run(
        ["zstd", "-q", "--no-progress", "-c"],
        input=raw,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"zstd compression failed: rc={proc.returncode}, stderr={proc.stderr.decode(errors='ignore')}"
        )
    return proc.stdout


def make_scattered_image(pattern_a: int, pattern_b: int) -> Tuple[bytes, List["Extent"], bytes]:
    blk_a = bytes([pattern_a]) * BLOCK_SIZE
    blk_b = bytes([pattern_b]) * BLOCK_SIZE
    img = bytearray(BLOCK_SIZE * 3)
    img[0:BLOCK_SIZE] = blk_a
    img[BLOCK_SIZE * 2 : BLOCK_SIZE * 3] = blk_b
    return bytes(img), [Extent(0, 1), Extent(2, 1)], blk_a + blk_b


def random_bytes(rnd: random.Random, length: int) -> bytes:
    """Generate low-compressibility random bytes."""
    return bytes(rnd.randrange(0, 256) for _ in range(length))


def semi_random_bytes(rnd: random.Random, length: int) -> bytes:
    """Generate bytes with some structure (medium compressibility)."""
    buf = bytearray(length)
    # Fill with repeating ~1KB chunks that have slight variation
    chunk = bytes(rnd.randrange(0, 256) for _ in range(1024))
    for i in range(0, length, 1024):
        end = min(i + 1024, length)
        # 10% chance to mutate the chunk
        if rnd.random() < 0.1:
            chunk = bytes(rnd.randrange(0, 256) for _ in range(1024))
        buf[i:end] = chunk[: end - i]
    return bytes(buf)


@dataclass
class Extent:
    start_block: int
    num_blocks: int


@dataclass
class Operation:
    op_type: str
    extents: List[Extent]
    blob: bytes

    @property
    def dst_length(self) -> int:
        return sum(e.num_blocks for e in self.extents) * BLOCK_SIZE


@dataclass
class PartitionSpec:
    name: str
    img: bytes
    op: Operation


def make_partition_spec(name: str, idx: int, rnd: random.Random, block_count: int) -> PartitionSpec:
    if name == "boot":
        boot_img, boot_extents, boot_raw = make_scattered_image(0x41, 0x42)
        return PartitionSpec(
            name="boot",
            img=boot_img,
            op=Operation("REPLACE", boot_extents, boot_raw),
        )

    if name == "vendor_boot":
        raw = bytes([0x56]) * (BLOCK_SIZE * max(2, block_count))
        return PartitionSpec(
            name="vendor_boot",
            img=raw,
            op=Operation("REPLACE_XZ", [Extent(0, max(2, block_count))], lzma.compress(raw, format=lzma.FORMAT_XZ)),
        )

    if name == "system_ext":
        raw = bytes([0x33]) * (BLOCK_SIZE * max(3, block_count))
        return PartitionSpec(
            name="system_ext",
            img=raw,
            op=Operation("REPLACE_BZ", [Extent(0, max(3, block_count))], bz2.compress(raw)),
        )

    if name == "product":
        raw = random_bytes(rnd, BLOCK_SIZE * block_count)
        return PartitionSpec(
            name="product",
            img=raw,
            op=Operation("ZSTD", [Extent(0, block_count)], zstd_compress(raw)),
        )

    if name == "vbmeta":
        img = bytes(BLOCK_SIZE)
        return PartitionSpec(
            name="vbmeta",
            img=img,
            op=Operation("ZERO", [Extent(0, 1)], b""),
        )

    op_type = ("REPLACE", "REPLACE_XZ", "REPLACE_BZ", "ZSTD", "ZERO")[idx % 5]

    if op_type == "ZERO":
        raw = bytes(BLOCK_SIZE * block_count)
        return PartitionSpec(name=name, img=raw, op=Operation("ZERO", [Extent(0, block_count)], b""))

    # Mix compressibility for realistic payload sizes
    if op_type in ("REPLACE", "REPLACE_XZ"):
        raw = semi_random_bytes(rnd, BLOCK_SIZE * block_count)
    elif op_type == "REPLACE_BZ":
        raw = semi_random_bytes(rnd, BLOCK_SIZE * block_count)
    else:  # ZSTD
        raw = random_bytes(rnd, BLOCK_SIZE * block_count)

    extents = [Extent(0, block_count)]

    if op_type == "REPLACE":
        return PartitionSpec(name=name, img=raw, op=Operation(op_type, extents, raw))
    if op_type == "REPLACE_XZ":
        return PartitionSpec(name=name, img=raw, op=Operation(op_type, extents, lzma.compress(raw, format=lzma.FORMAT_XZ)))
    if op_type == "REPLACE_BZ":
        return PartitionSpec(name=name, img=raw, op=Operation(op_type, extents, bz2.compress(raw)))
    return PartitionSpec(name=name, img=raw, op=Operation("ZSTD", extents, zstd_compress(raw)))


def generate_specs(seed: int, total_mb: int) -> List[PartitionSpec]:
    rnd = random.Random(seed)
    # Calculate blocks per partition to reach target raw size.
    # Special partitions have fixed or minimum sizes; distribute remainder.
    fixed_blocks = {
        "boot": 3,
        "vendor_boot": max(2, 1),
        "system_ext": max(3, 1),
        "vbmeta": 1,
    }
    target_blocks = (total_mb * 1024 * 1024) // BLOCK_SIZE
    special_min = sum(fixed_blocks.get(n, 0) for n in SPECIAL_PARTITIONS)
    remaining = target_blocks - special_min
    other_count = len(ALL_PARTITIONS) - len(SPECIAL_PARTITIONS)
    base_blocks = max(1, remaining // other_count)
    extra = remaining - base_blocks * other_count

    specs: List[PartitionSpec] = []
    for idx, name in enumerate(ALL_PARTITIONS):
        if name in fixed_blocks:
            bc = fixed_blocks[name]
        else:
            bc = base_blocks + (1 if idx < extra else 0)
        specs.append(make_partition_spec(name, idx, rnd, bc))
    return specs


def op_type_to_proto_enum(name: str) -> str:
    return name


def bytes_to_proto_string(blob: bytes) -> str:
    return '"' + "".join(f"\\x{b:02x}" for b in blob) + '"'


def build_manifest_text(specs: List[PartitionSpec]) -> Tuple[str, bytes]:
    lines: List[str] = []
    lines.append("block_size: 4096")
    lines.append("minor_version: 9")

    data_blob = bytearray()
    cur_off = 0
    for spec in specs:
        op = spec.op
        data_len = len(op.blob)
        data_sha = hashlib.sha256(op.blob).digest()

        lines.append("partitions {")
        lines.append(f'  partition_name: "{spec.name}"')
        lines.append("  new_partition_info {")
        lines.append(f"    size: {len(spec.img)}")
        lines.append("  }")
        lines.append("  operations {")
        lines.append(f"    type: {op_type_to_proto_enum(op.op_type)}")
        lines.append(f"    data_offset: {cur_off}")
        lines.append(f"    data_length: {data_len}")
        for ex in op.extents:
            lines.append("    dst_extents {")
            lines.append(f"      start_block: {ex.start_block}")
            lines.append(f"      num_blocks: {ex.num_blocks}")
            lines.append("    }")
        lines.append(f"    dst_length: {op.dst_length}")
        if data_len > 0:
            lines.append(f"    data_sha256_hash: {bytes_to_proto_string(data_sha)}")
        lines.append("  }")
        lines.append("}")

        data_blob.extend(op.blob)
        cur_off += data_len

    return "\n".join(lines) + "\n", bytes(data_blob)


def protoc_encode_manifest(proto_path: Path, text: str) -> bytes:
    cmd = [
        "protoc",
        f"--proto_path={proto_path.parent}",
        "--encode=chromeos_update_engine.DeltaArchiveManifest",
        str(proto_path.name),
    ]
    proc = subprocess.run(cmd, input=text.encode(), capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(
            f"protoc manifest encode failed: rc={proc.returncode}, stderr={proc.stderr.decode(errors='ignore')}"
        )
    return proc.stdout


def write_payload(payload_path: Path, manifest_bin: bytes, signatures_bin: bytes, blobs: bytes) -> None:
    with payload_path.open("wb") as f:
        f.write(b"CrAU")
        f.write(struct.pack(">Q", 2))
        f.write(struct.pack(">Q", len(manifest_bin)))
        f.write(struct.pack(">I", len(signatures_bin)))
        f.write(manifest_bin)
        f.write(signatures_bin)
        f.write(blobs)


def payload_metadata_blob(manifest_bin: bytes, signatures_bin: bytes) -> bytes:
    header = b"".join(
        (
            b"CrAU",
            struct.pack(">Q", 2),
            struct.pack(">Q", len(manifest_bin)),
            struct.pack(">I", len(signatures_bin)),
        )
    )
    return header + manifest_bin + signatures_bin


def build_payload_properties(payload_bytes: bytes, metadata_bytes: bytes) -> bytes:
    lines = [
        "FILE_HASH=" + base64.b64encode(hashlib.sha256(payload_bytes).digest()).decode("ascii"),
        f"FILE_SIZE={len(payload_bytes)}",
        "METADATA_HASH=" + base64.b64encode(hashlib.sha256(metadata_bytes).digest()).decode("ascii"),
        f"METADATA_SIZE={len(metadata_bytes)}",
    ]
    return ("\n".join(lines) + "\n").encode("utf-8")


def write_ota_zip(ota_zip_path: Path, payload_path: Path, payload_properties: bytes) -> None:
    metadata = (
        "ota-type=AB\n"
        "post-timestamp=0\n"
        "post-build=eng.sample\n"
        "pre-device=sample_device\n"
    ).encode("utf-8")

    with zipfile.ZipFile(ota_zip_path, "w", compression=zipfile.ZIP_STORED) as zf:
        zf.writestr("payload.bin", payload_path.read_bytes())
        zf.writestr("payload_properties.txt", payload_properties)
        zf.writestr("META-INF/com/android/metadata", metadata)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-root", default="tests/data/generated", help="output root directory")
    ap.add_argument("--name", default="sample", help="sample name")
    ap.add_argument("--seed", type=int, default=None, help="random seed for reproducibility")
    ap.add_argument("--total-mb", type=int, default=128, help="target raw partition size in MB")
    args = ap.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    proto_path = repo_root / "proto" / "update_metadata.proto"
    out_root = (repo_root / args.out_root).resolve()
    sample_root = out_root / args.name
    payload_path = sample_root / "payload.bin"
    ota_zip_path = sample_root / "ota_update.zip"
    extracted_dir = sample_root / "extracted"
    manifest_txt_path = sample_root / "manifest.textproto"

    if sample_root.exists():
        shutil.rmtree(sample_root)
    extracted_dir.mkdir(parents=True, exist_ok=True)

    seed = args.seed
    if seed is None:
        seed = (time.time_ns() ^ os.getpid() ^ int.from_bytes(os.urandom(8), "little")) & ((1 << 63) - 1)

    specs = generate_specs(seed, args.total_mb)
    manifest_text, data_blobs = build_manifest_text(specs)
    manifest_txt_path.write_text(manifest_text)

    manifest_bin = protoc_encode_manifest(proto_path, manifest_text)
    signatures_bin = b""
    write_payload(payload_path, manifest_bin, signatures_bin, data_blobs)
    payload_bytes = payload_path.read_bytes()
    metadata_bytes = payload_metadata_blob(manifest_bin, signatures_bin)
    payload_properties = build_payload_properties(payload_bytes, metadata_bytes)
    write_ota_zip(ota_zip_path, payload_path, payload_properties)

    for spec in specs:
        (extracted_dir / f"{spec.name}.img").write_bytes(spec.img)

    print(f"[OK] generated payload: {payload_path}")
    print(f"[OK] generated ota zip: {ota_zip_path}")
    print(f"[OK] generated golden dir: {extracted_dir}")
    print(f"[INFO] seed: {seed}")
    print(f"[INFO] manifest text: {manifest_txt_path}")
    print(f"[INFO] payload size: {payload_path.stat().st_size:,} bytes")
    print(f"[INFO] raw partition total: {sum(len(s.img) for s in specs):,} bytes")


if __name__ == "__main__":
    main()
