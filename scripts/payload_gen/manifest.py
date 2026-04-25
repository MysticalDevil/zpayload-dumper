"""Manifest textproto building and protobuf encoding."""

from __future__ import annotations

import hashlib
import importlib
import subprocess
import sys
import tempfile
from pathlib import Path
from types import ModuleType

from payload_gen.models import PartitionSpec
from payload_gen.paths import PROTO_DIR


def _bytes_to_proto_string(blob: bytes) -> str:
    return '"' + "".join(f"\\x{byte:02x}" for byte in blob) + '"'


def build_manifest_text(specs: list[PartitionSpec]) -> tuple[str, bytes]:
    lines: list[str] = ["block_size: 4096", "minor_version: 9"]
    data_blob = bytearray()
    cur_off = 0

    for spec in specs:
        op = spec.op
        data_sha = hashlib.sha256(op.blob).digest()
        lines.append("partitions {")
        lines.append(f'  partition_name: "{spec.name}"')
        lines.append("  new_partition_info {")
        lines.append(f"    size: {len(spec.img)}")
        lines.append("  }")
        lines.append("  operations {")
        lines.append(f"    type: {op.op_type}")
        lines.append(f"    data_offset: {cur_off}")
        lines.append(f"    data_length: {len(op.blob)}")
        for extent in op.extents:
            lines.append("    dst_extents {")
            lines.append(f"      start_block: {extent.start_block}")
            lines.append(f"      num_blocks: {extent.num_blocks}")
            lines.append("    }")
        lines.append(f"    dst_length: {op.dst_length}")
        if op.blob:
            lines.append(f"    data_sha256_hash: {_bytes_to_proto_string(data_sha)}")
        lines.append("  }")
        lines.append("}")
        data_blob.extend(op.blob)
        cur_off += len(op.blob)

    return "\n".join(lines) + "\n", bytes(data_blob)


def _ensure_pb2(proto_dir: Path, out_dir: Path) -> Path:
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


def load_update_metadata_pb2(proto_dir: Path | None = None) -> ModuleType:
    proto_dir = proto_dir or PROTO_DIR
    pb2_dir = Path(tempfile.gettempdir()) / "zpayload_pb2"
    _ensure_pb2(proto_dir, pb2_dir)
    sys.path.insert(0, str(pb2_dir))
    return importlib.import_module("update_metadata_pb2")
