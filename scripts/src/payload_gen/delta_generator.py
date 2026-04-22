"""Generate synthetic delta payloads with SOURCE_BSDIFF operations."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
from pathlib import Path

import bsdiff4
from google.protobuf import text_format

from payload_gen.payload_format import (
    build_payload_bytes,
    build_payload_properties,
    payload_metadata_blob,
    write_ota_tar,
    write_ota_zip,
    write_payload_file,
)
from payload_gen.project import PROTO_DIR, REPO_ROOT
from payload_gen.proto_codegen import load_update_metadata_pb2


def pad_block_aligned(data: bytes, block_size: int) -> bytes:
    remainder = len(data) % block_size
    if remainder == 0:
        return data
    return data + b"\x00" * (block_size - remainder)


def build_manifest(
    pb2: object,
    *,
    partition_name: str,
    block_size: int,
    old_size: int,
    new_size: int,
    patch_offset: int,
    patch_length: int,
    patch_sha256: bytes,
    src_sha256: bytes,
) -> object:
    manifest = pb2.DeltaArchiveManifest()
    manifest.block_size = block_size
    manifest.minor_version = 4

    old_blocks = (old_size + block_size - 1) // block_size
    new_blocks = (new_size + block_size - 1) // block_size

    part = manifest.partitions.add()
    part.partition_name = partition_name
    part.old_partition_info.size = old_size
    part.new_partition_info.size = new_size

    op = part.operations.add()
    op.type = pb2.InstallOperation.Type.SOURCE_BSDIFF
    op.data_offset = patch_offset
    op.data_length = patch_length
    op.src_length = old_size
    op.dst_length = new_size
    op.data_sha256_hash = patch_sha256
    op.src_sha256_hash = src_sha256

    src = op.src_extents.add()
    src.start_block = 0
    src.num_blocks = old_blocks

    dst = op.dst_extents.add()
    dst.start_block = 0
    dst.num_blocks = new_blocks

    return manifest


def write_fixture_bundle(
    bundle_dir: Path,
    *,
    partition_name: str,
    old_data: bytes,
    new_data: bytes,
    payload_bytes: bytes,
    payload_properties: bytes,
    manifest_text: str,
) -> None:
    if bundle_dir.exists():
        shutil.rmtree(bundle_dir)
    old_dir = bundle_dir / "old"
    extracted_dir = bundle_dir / "extracted"
    old_dir.mkdir(parents=True, exist_ok=True)
    extracted_dir.mkdir(parents=True, exist_ok=True)

    payload_path = bundle_dir / "payload.bin"
    ota_zip_path = bundle_dir / "ota_update.zip"
    ota_tar_path = bundle_dir / "ota_update.tar"
    ota_tgz_path = bundle_dir / "ota_update.tar.gz"
    manifest_path = bundle_dir / "manifest.textproto"
    expected_path = bundle_dir / "expected_result.txt"
    scenario_path = bundle_dir / "scenario.txt"

    write_payload_file(payload_path, payload_bytes)
    write_ota_zip(
        ota_zip_path,
        payload_bytes=payload_bytes,
        payload_properties=payload_properties,
        include_payload=True,
    )
    write_ota_tar(
        ota_tar_path,
        payload_bytes=payload_bytes,
        payload_properties=payload_properties,
        include_payload=True,
        compress=False,
    )
    write_ota_tar(
        ota_tgz_path,
        payload_bytes=payload_bytes,
        payload_properties=payload_properties,
        include_payload=True,
        compress=True,
    )
    manifest_path.write_text(manifest_text)
    (old_dir / f"{partition_name}.img").write_bytes(old_data)
    (extracted_dir / f"{partition_name}.img").write_bytes(new_data)
    expected_path.write_text("success\n")
    scenario_path.write_text(
        "\n".join(
            [
                "scenario=source_bsdiff_delta",
                f"partition_name={partition_name}",
                "expected=success",
            ]
        )
        + "\n"
    )

    print(f"[OK] fixture bundle written to {bundle_dir}")
    print(f"[OK] generated ota zip: {ota_zip_path}")
    print(f"[OK] generated ota tar: {ota_tar_path}")
    print(f"[OK] generated ota tgz: {ota_tgz_path}")
    print(f"[INFO] old images: {old_dir}")
    print(f"[INFO] expected extracted images: {extracted_dir}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old", required=True, help="path to old partition image")
    parser.add_argument("--new", required=True, help="path to new partition image")
    parser.add_argument("--partition-name", default="test", help="partition name in manifest")
    parser.add_argument("--output", "-o", required=True, help="output payload.bin path")
    parser.add_argument(
        "--bundle-dir",
        type=Path,
        help="optional fixture bundle directory; writes payload.bin, ota_update.zip, old/, extracted/, and manifest.textproto",
    )
    parser.add_argument("--block-size", type=int, default=4096, help="block size (default: 4096)")
    parser.add_argument("--proto-dir", type=Path, default=PROTO_DIR, help="directory containing update_metadata.proto")
    parser.add_argument(
        "--check-with",
        type=Path,
        default=REPO_ROOT / "zig-out" / "bin" / "zpayload-dumper",
        help="optional zpayload-dumper binary used for a quick -l sanity check",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    old_path = Path(args.old)
    new_path = Path(args.new)
    if not old_path.exists():
        raise SystemExit(f"old image not found: {old_path}")
    if not new_path.exists():
        raise SystemExit(f"new image not found: {new_path}")

    old_data = pad_block_aligned(old_path.read_bytes(), args.block_size)
    new_data = pad_block_aligned(new_path.read_bytes(), args.block_size)
    if len(old_data) != old_path.stat().st_size:
        print(f"[INFO] padded old image to {len(old_data)} bytes")
    if len(new_data) != new_path.stat().st_size:
        print(f"[INFO] padded new image to {len(new_data)} bytes")

    patch = bsdiff4.diff(old_data, new_data)
    print(f"[INFO] bsdiff patch size: {len(patch)} bytes (old={len(old_data)}, new={len(new_data)})")
    patch_sha256 = hashlib.sha256(patch).digest()
    src_sha256 = hashlib.sha256(old_data).digest()

    pb2 = load_update_metadata_pb2(args.proto_dir)
    manifest = build_manifest(
        pb2,
        partition_name=args.partition_name,
        block_size=args.block_size,
        old_size=len(old_data),
        new_size=len(new_data),
        patch_offset=0,
        patch_length=len(patch),
        patch_sha256=patch_sha256,
        src_sha256=src_sha256,
    )
    manifest_bytes = manifest.SerializeToString()
    manifest_text = text_format.MessageToString(manifest)
    print(f"[INFO] manifest size: {len(manifest_bytes)} bytes")

    payload_bytes = build_payload_bytes(manifest_bytes, patch)
    metadata_bytes = payload_metadata_blob(manifest_bytes)
    payload_properties = build_payload_properties(payload_bytes, metadata_bytes)
    write_payload_file(Path(args.output), payload_bytes)
    print(f"[OK] payload written to {args.output}")

    if args.bundle_dir is not None:
        write_fixture_bundle(
            args.bundle_dir,
            partition_name=args.partition_name,
            old_data=old_data,
            new_data=new_data,
            payload_bytes=payload_bytes,
            payload_properties=payload_properties,
            manifest_text=manifest_text,
        )

    if args.check_with.exists():
        result = subprocess.run([str(args.check_with), "-l", args.output], capture_output=True, text=True, check=False)
        if result.returncode == 0:
            print("[OK] zpayload-dumper -l sanity check passed")
        else:
            print("[WARN] zpayload-dumper -l failed")
            if result.stderr.strip():
                print(result.stderr.strip())
    else:
        print(f"[INFO] zpayload-dumper not found at {args.check_with}, skipping sanity check")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
