#!/usr/bin/env python3
"""
Generate a tiny synthetic Android payload.bin and matching extracted images.

Usage:
  python3 scripts/generate_sample_payload.py
  python3 scripts/generate_sample_payload.py --out-root testdata/generated --name demo
"""

from __future__ import annotations

import argparse
import bz2
import hashlib
import lzma
import os
import random
import shutil
import struct
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple

BLOCK_SIZE = 4096


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


def make_scattered_image(pattern_a: int, pattern_b: int) -> Tuple[bytes, List[Extent], bytes]:
    blk_a = bytes([pattern_a]) * BLOCK_SIZE
    blk_b = bytes([pattern_b]) * BLOCK_SIZE
    # Write to block 0 and block 2 to keep a sparse/gap block in the middle.
    img = bytearray(BLOCK_SIZE * 3)
    img[0:BLOCK_SIZE] = blk_a
    img[BLOCK_SIZE * 2 : BLOCK_SIZE * 3] = blk_b
    return bytes(img), [Extent(0, 1), Extent(2, 1)], blk_a + blk_b


def generate_specs(seed: int) -> List[PartitionSpec]:
    rnd = random.Random(seed)

    boot_img, boot_extents, boot_raw = make_scattered_image(0x41, 0x42)
    boot = PartitionSpec(
        name="boot",
        img=boot_img,
        op=Operation("REPLACE", boot_extents, boot_raw),
    )

    vendor_boot_raw = bytes([0x56]) * (BLOCK_SIZE * 2)
    vendor_boot_img = vendor_boot_raw
    vendor_boot = PartitionSpec(
        name="vendor_boot",
        img=vendor_boot_img,
        op=Operation("REPLACE_XZ", [Extent(0, 2)], lzma.compress(vendor_boot_raw, format=lzma.FORMAT_XZ)),
    )

    system_ext_raw = bytes([0x33]) * (BLOCK_SIZE * 3)
    system_ext = PartitionSpec(
        name="system_ext",
        img=system_ext_raw,
        op=Operation("REPLACE_BZ", [Extent(0, 3)], bz2.compress(system_ext_raw)),
    )

    product_raw = bytes(rnd.randrange(0, 256) for _ in range(BLOCK_SIZE * 4))
    product = PartitionSpec(
        name="product",
        img=product_raw,
        op=Operation("ZSTD", [Extent(0, 4)], zstd_compress(product_raw)),
    )

    vbmeta_img = bytes(BLOCK_SIZE)  # ZERO op result.
    vbmeta = PartitionSpec(
        name="vbmeta",
        img=vbmeta_img,
        op=Operation("ZERO", [Extent(0, 1)], b""),
    )

    return [boot, vendor_boot, system_ext, product, vbmeta]


def op_type_to_proto_enum(name: str) -> str:
    mapping = {
        "REPLACE": "REPLACE",
        "REPLACE_XZ": "REPLACE_XZ",
        "REPLACE_BZ": "REPLACE_BZ",
        "ZSTD": "ZSTD",
        "ZERO": "ZERO",
    }
    return mapping[name]


def bytes_to_proto_string(blob: bytes) -> str:
    # Protobuf text format bytes literal.
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


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-root", default="testdata/generated", help="output root directory")
    ap.add_argument("--name", default="sample", help="sample name")
    ap.add_argument("--seed", type=int, default=None, help="random seed for reproducibility")
    args = ap.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    proto_path = repo_root / "proto" / "update_metadata.proto"
    out_root = (repo_root / args.out_root).resolve()
    sample_root = out_root / args.name
    payload_path = sample_root / "payload.bin"
    extracted_dir = sample_root / "extracted"
    manifest_txt_path = sample_root / "manifest.textproto"

    if sample_root.exists():
        shutil.rmtree(sample_root)
    extracted_dir.mkdir(parents=True, exist_ok=True)

    seed = args.seed
    if seed is None:
        seed = (time.time_ns() ^ os.getpid() ^ int.from_bytes(os.urandom(8), "little")) & ((1 << 63) - 1)

    specs = generate_specs(seed)
    manifest_text, data_blobs = build_manifest_text(specs)
    manifest_txt_path.write_text(manifest_text)

    manifest_bin = protoc_encode_manifest(proto_path, manifest_text)
    signatures_bin = b""
    write_payload(payload_path, manifest_bin, signatures_bin, data_blobs)

    for spec in specs:
        (extracted_dir / f"{spec.name}.img").write_bytes(spec.img)

    print(f"[OK] generated payload: {payload_path}")
    print(f"[OK] generated golden dir: {extracted_dir}")
    print(f"[INFO] seed: {seed}")
    print(f"[INFO] manifest text: {manifest_txt_path}")
    print(f"[INFO] payload size: {payload_path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
