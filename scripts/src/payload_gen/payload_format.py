from __future__ import annotations

import base64
import hashlib
import struct
import zipfile
from pathlib import Path


def build_payload_bytes(
    manifest_bytes: bytes,
    data_blob: bytes,
    *,
    signatures_bytes: bytes = b"",
    version: int = 2,
) -> bytes:
    return b"".join(
        (
            b"CrAU",
            struct.pack(">Q", version),
            struct.pack(">Q", len(manifest_bytes)),
            struct.pack(">I", len(signatures_bytes)),
            manifest_bytes,
            signatures_bytes,
            data_blob,
        )
    )


def payload_metadata_blob(manifest_bytes: bytes, signatures_bytes: bytes = b"", *, version: int = 2) -> bytes:
    return b"".join(
        (
            b"CrAU",
            struct.pack(">Q", version),
            struct.pack(">Q", len(manifest_bytes)),
            struct.pack(">I", len(signatures_bytes)),
            manifest_bytes,
            signatures_bytes,
        )
    )


def build_payload_properties(payload_bytes: bytes, metadata_bytes: bytes) -> bytes:
    lines = [
        "FILE_HASH=" + base64.b64encode(hashlib.sha256(payload_bytes).digest()).decode("ascii"),
        f"FILE_SIZE={len(payload_bytes)}",
        "METADATA_HASH=" + base64.b64encode(hashlib.sha256(metadata_bytes).digest()).decode("ascii"),
        f"METADATA_SIZE={len(metadata_bytes)}",
    ]
    return ("\n".join(lines) + "\n").encode("utf-8")


def write_payload_file(path: Path, payload_bytes: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload_bytes)


def write_ota_zip(
    path: Path,
    *,
    payload_bytes: bytes,
    payload_properties: bytes,
    include_payload: bool = True,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    metadata = (
        "ota-type=AB\n"
        "post-timestamp=0\n"
        "post-build=eng.sample\n"
        "pre-device=sample_device\n"
    ).encode("utf-8")

    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as zf:
        if include_payload:
            zf.writestr("payload.bin", payload_bytes)
        zf.writestr("payload_properties.txt", payload_properties)
        zf.writestr("META-INF/com/android/metadata", metadata)
