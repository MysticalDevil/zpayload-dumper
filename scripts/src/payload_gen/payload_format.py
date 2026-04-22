from __future__ import annotations

import base64
import gzip
import hashlib
import struct
import tarfile
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


def _write_ota_archive(
    path: Path,
    *,
    payload_bytes: bytes,
    payload_properties: bytes,
    include_payload: bool = True,
) -> None:
    """Write the common OTA files into an already-opened archive."""
    metadata = (
        "ota-type=AB\n"
        "post-timestamp=0\n"
        "post-build=eng.sample\n"
        "pre-device=sample_device\n"
    ).encode("utf-8")

    if include_payload:
        path.write_bytes(payload_bytes)
    (path.parent / "payload_properties.txt").write_bytes(payload_properties)
    (path.parent / "META-INF/com/android/metadata").write_bytes(metadata)


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


def write_ota_tar(
    path: Path,
    *,
    payload_bytes: bytes,
    payload_properties: bytes,
    include_payload: bool = True,
    compress: bool = False,
) -> None:
    """Write OTA files into a tar archive (optionally gzip-compressed)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    metadata = (
        "ota-type=AB\n"
        "post-timestamp=0\n"
        "post-build=eng.sample\n"
        "pre-device=sample_device\n"
    ).encode("utf-8")

    mode = "w:gz" if compress else "w"
    with tarfile.open(path, mode) as tf:
        if include_payload:
            import io

            payload_io = io.BytesIO(payload_bytes)
            info = tarfile.TarInfo(name="payload.bin")
            info.size = len(payload_bytes)
            tf.addfile(info, payload_io)

        props_io = io.BytesIO(payload_properties)
        info = tarfile.TarInfo(name="payload_properties.txt")
        info.size = len(payload_properties)
        tf.addfile(info, props_io)

        meta_io = io.BytesIO(metadata)
        info = tarfile.TarInfo(name="META-INF/com/android/metadata")
        info.size = len(metadata)
        tf.addfile(info, meta_io)
