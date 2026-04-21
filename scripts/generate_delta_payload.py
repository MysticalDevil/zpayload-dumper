#!/usr/bin/env python3
"""Generate a synthetic delta OTA payload with SOURCE_BSDIFF operations.

Usage:
    uv run python generate_delta_payload.py \
        --old old_boot.img --new new_boot.img \
        --partition-name boot --output test_payload.bin

The script creates a minimal payload.bin containing a single partition
with a SOURCE_BSDIFF operation. The bsdiff patch is computed from the
old and new image files using the bsdiff4 library.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import struct
import sys
import tempfile
from pathlib import Path


def ensure_pb2(proto_dir: Path, out_dir: Path) -> Path:
    """Generate update_metadata_pb2.py from .proto if needed."""
    pb2_path = out_dir / "update_metadata_pb2.py"
    if pb2_path.exists():
        return pb2_path
    out_dir.mkdir(parents=True, exist_ok=True)
    proto_file = proto_dir / "update_metadata.proto"
    if not proto_file.exists():
        raise FileNotFoundError(f"Proto file not found: {proto_file}")
    subprocess.run(
        ["protoc", f"--python_out={out_dir}", f"--proto_path={proto_dir}", str(proto_file)],
        check=True,
    )
    return pb2_path


def write_payload(
    output_path: Path,
    manifest_bytes: bytes,
    data_blob: bytes,
) -> None:
    """Write payload.bin in Android CrAU format."""
    with open(output_path, "wb") as f:
        # Magic
        f.write(b"CrAU")
        # file_format_version = 2
        f.write(struct.pack(">Q", 2))
        # manifest_size
        f.write(struct.pack(">Q", len(manifest_bytes)))
        # metadata_signature_size
        f.write(struct.pack(">I", 0))
        # manifest
        f.write(manifest_bytes)
        # metadata_signature_message (empty)
        # data blobs
        f.write(data_blob)
        # payload_signatures_message_size
        f.write(struct.pack(">Q", 0))
        # payload_signatures_message (empty)


def make_extent(start_block: int, num_blocks: int) -> object:
    """Create an Extent protobuf message."""
    # Delayed import so we can generate pb2 first
    from update_metadata_pb2 import Extent

    e = Extent()
    e.start_block = start_block
    e.num_blocks = num_blocks
    return e


def make_operation(
    op_type: int,
    data_offset: int,
    data_length: int,
    src_extents: list[tuple[int, int]],
    dst_extents: list[tuple[int, int]],
    src_length: int | None = None,
    dst_length: int | None = None,
) -> object:
    """Create an InstallOperation protobuf message."""
    from update_metadata_pb2 import InstallOperation

    op = InstallOperation()
    op.type = op_type
    op.data_offset = data_offset
    op.data_length = data_length
    for start, num in src_extents:
        e = op.src_extents.add()
        e.start_block = start
        e.num_blocks = num
    for start, num in dst_extents:
        e = op.dst_extents.add()
        e.start_block = start
        e.num_blocks = num
    if src_length is not None:
        op.src_length = src_length
    if dst_length is not None:
        op.dst_length = dst_length
    return op


def build_manifest(
    partition_name: str,
    block_size: int,
    old_size: int,
    new_size: int,
    patch_offset: int,
    patch_length: int,
) -> bytes:
    """Build a DeltaArchiveManifest protobuf for a single SOURCE_BSDIFF operation."""
    from update_metadata_pb2 import DeltaArchiveManifest, PartitionUpdate, PartitionInfo, InstallOperation

    old_blocks = (old_size + block_size - 1) // block_size
    new_blocks = (new_size + block_size - 1) // block_size

    manifest = DeltaArchiveManifest()
    manifest.block_size = block_size
    manifest.minor_version = 4  # supports ZERO, DISCARD, BROTLI_BSDIFF, etc.

    part = manifest.partitions.add()
    part.partition_name = partition_name

    old_info = PartitionInfo()
    old_info.size = old_size
    part.old_partition_info.CopyFrom(old_info)

    new_info = PartitionInfo()
    new_info.size = new_size
    part.new_partition_info.CopyFrom(new_info)

    op = part.operations.add()
    op.type = InstallOperation.Type.SOURCE_BSDIFF
    op.data_offset = patch_offset
    op.data_length = patch_length
    op.src_length = old_size
    op.dst_length = new_size

    # Single src extent covering entire old image
    se = op.src_extents.add()
    se.start_block = 0
    se.num_blocks = old_blocks

    # Single dst extent covering entire new image
    de = op.dst_extents.add()
    de.start_block = 0
    de.num_blocks = new_blocks

    return manifest.SerializeToString()


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a synthetic delta payload with SOURCE_BSDIFF")
    parser.add_argument("--old", required=True, help="Path to old partition image")
    parser.add_argument("--new", required=True, help="Path to new partition image")
    parser.add_argument("--partition-name", default="test", help="Partition name in manifest")
    parser.add_argument("--output", "-o", required=True, help="Output payload.bin path")
    parser.add_argument("--block-size", type=int, default=4096, help="Block size (default: 4096)")
    parser.add_argument(
        "--proto-dir",
        type=Path,
        default=Path(__file__).parent.parent / "proto",
        help="Directory containing update_metadata.proto",
    )
    args = parser.parse_args()

    old_path = Path(args.old)
    new_path = Path(args.new)
    if not old_path.exists():
        parser.error(f"Old image not found: {old_path}")
    if not new_path.exists():
        parser.error(f"New image not found: {new_path}")

    old_data = old_path.read_bytes()
    new_data = new_path.read_bytes()

    # Ensure images are block-aligned for realism
    if len(old_data) % args.block_size != 0:
        old_data = old_data + b"\x00" * (args.block_size - len(old_data) % args.block_size)
        print(f"[INFO] padded old image to {len(old_data)} bytes (block aligned)")
    if len(new_data) % args.block_size != 0:
        new_data = new_data + b"\x00" * (args.block_size - len(new_data) % args.block_size)
        print(f"[INFO] padded new image to {len(new_data)} bytes (block aligned)")

    # Generate bsdiff patch
    import bsdiff4

    patch = bsdiff4.diff(old_data, new_data)
    print(f"[INFO] bsdiff patch size: {len(patch)} bytes (old={len(old_data)}, new={len(new_data)})")

    # Build manifest
    pb2_dir = Path(tempfile.gettempdir()) / "zpayload_pb2"
    pb2_path = ensure_pb2(args.proto_dir, pb2_dir)
    sys.path.insert(0, str(pb2_dir))

    # Need to import after path insertion
    from update_metadata_pb2 import InstallOperation

    manifest_bytes = build_manifest(
        partition_name=args.partition_name,
        block_size=args.block_size,
        old_size=len(old_data),
        new_size=len(new_data),
        patch_offset=0,
        patch_length=len(patch),
    )
    print(f"[INFO] manifest size: {len(manifest_bytes)} bytes")

    # Write payload
    write_payload(Path(args.output), manifest_bytes, patch)
    print(f"[OK] payload written to {args.output}")

    # Quick sanity: list with zpayload-dumper
    zp = Path(__file__).parent.parent / "zig-out" / "bin" / "zpayload-dumper"
    if zp.exists():
        result = subprocess.run([str(zp), "-l", args.output], capture_output=True, text=True)
        if result.returncode == 0:
            print("[OK] zpayload-dumper -l output:")
            for line in result.stderr.splitlines() + result.stdout.splitlines():
                if line.strip():
                    print(f"    {line}")
        else:
            print("[WARN] zpayload-dumper -l failed:")
            print(result.stderr)
    else:
        print(f"[INFO] zpayload-dumper not found at {zp}, skipping list check")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
