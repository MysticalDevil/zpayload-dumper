"""Unified bundle writer for sample and delta fixtures."""

from __future__ import annotations

import shutil
from pathlib import Path

from payload_gen.format import (
    write_ota_tar,
    write_ota_zip,
    write_payload_file,
)
from payload_gen.models import PartitionSpec


def write_bundle(
    bundle_dir: Path,
    *,
    specs: list[PartitionSpec],
    payload_bytes: bytes,
    payload_properties: bytes,
    manifest_text: str,
    scenario_lines: list[str],
    expected_text: str,
    include_payload: bool = True,
    old_images: dict[str, bytes] | None = None,
) -> None:
    if bundle_dir.exists():
        shutil.rmtree(bundle_dir)

    extracted_dir = bundle_dir / "extracted"
    extracted_dir.mkdir(parents=True, exist_ok=True)

    payload_path = bundle_dir / "payload.bin"
    ota_zip_path = bundle_dir / "ota_update.zip"
    ota_tar_path = bundle_dir / "ota_update.tar"
    ota_tgz_path = bundle_dir / "ota_update.tar.gz"

    write_payload_file(payload_path, payload_bytes)
    write_ota_zip(
        ota_zip_path,
        payload_bytes=payload_bytes,
        payload_properties=payload_properties,
        include_payload=include_payload,
    )
    write_ota_tar(
        ota_tar_path,
        payload_bytes=payload_bytes,
        payload_properties=payload_properties,
        include_payload=include_payload,
        compress=False,
    )
    write_ota_tar(
        ota_tgz_path,
        payload_bytes=payload_bytes,
        payload_properties=payload_properties,
        include_payload=include_payload,
        compress=True,
    )

    for spec in specs:
        (extracted_dir / f"{spec.name}.img").write_bytes(spec.img)

    if old_images:
        old_dir = bundle_dir / "old"
        old_dir.mkdir(parents=True, exist_ok=True)
        for name, data in old_images.items():
            (old_dir / f"{name}.img").write_bytes(data)

    (bundle_dir / "manifest.textproto").write_text(manifest_text)
    (bundle_dir / "scenario.txt").write_text("\n".join(scenario_lines) + "\n")
    (bundle_dir / "expected_result.txt").write_text(expected_text)

    print(f"[OK] generated payload: {payload_path}")
    print(f"[OK] generated ota zip: {ota_zip_path}")
    print(f"[OK] generated ota tar: {ota_tar_path}")
    print(f"[OK] generated ota tgz: {ota_tgz_path}")
    print(f"[OK] generated golden dir: {extracted_dir}")
