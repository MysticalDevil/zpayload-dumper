from __future__ import annotations

import importlib
import subprocess
import sys
import tempfile
from pathlib import Path
from types import ModuleType


def ensure_pb2(proto_dir: Path, out_dir: Path) -> Path:
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


def load_update_metadata_pb2(proto_dir: Path) -> ModuleType:
    pb2_dir = Path(tempfile.gettempdir()) / "zpayload_pb2"
    ensure_pb2(proto_dir, pb2_dir)
    sys.path.insert(0, str(pb2_dir))
    return importlib.import_module("update_metadata_pb2")
