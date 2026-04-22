"""Generate synthetic valid and invalid payload/OTA fixtures for tests."""

from __future__ import annotations

import argparse
import bz2
import lzma
import os
import random
import time
from pathlib import Path

from payload_gen.constants import (
    ALL_PARTITIONS,
    BLOCK_SIZE,
    DEFAULT_SCENARIO,
    SCENARIOS,
    SPECIAL_PARTITIONS,
)
from payload_gen.format import (
    build_payload_bytes,
    build_payload_properties,
    payload_metadata_blob,
)
from payload_gen.manifest import build_manifest_text, load_update_metadata_pb2
from payload_gen.models import Extent, Operation, PartitionSpec, SampleArtifacts
from payload_gen.paths import PROTO_DIR, REPO_ROOT
from payload_gen.utils import random_bytes, semi_random_bytes, zstd_compress
from payload_gen.writer import write_bundle


def make_scattered_image(pattern_a: int, pattern_b: int) -> tuple[bytes, list[Extent], bytes]:
    blk_a = bytes([pattern_a]) * BLOCK_SIZE
    blk_b = bytes([pattern_b]) * BLOCK_SIZE
    img = bytearray(BLOCK_SIZE * 3)
    img[0:BLOCK_SIZE] = blk_a
    img[BLOCK_SIZE * 2 : BLOCK_SIZE * 3] = blk_b
    return bytes(img), [Extent(0, 1), Extent(2, 1)], blk_a + blk_b


def make_partition_spec(name: str, idx: int, rnd: random.Random, block_count: int) -> PartitionSpec:
    if name == "boot":
        boot_img, boot_extents, boot_raw = make_scattered_image(0x41, 0x42)
        return PartitionSpec("boot", boot_img, Operation("REPLACE", boot_extents, boot_raw))

    if name == "vendor_boot":
        raw = bytes([0x56]) * (BLOCK_SIZE * max(2, block_count))
        return PartitionSpec(
            "vendor_boot", raw,
            Operation("REPLACE_XZ", [Extent(0, max(2, block_count))], lzma.compress(raw, format=lzma.FORMAT_XZ)),
        )

    if name == "system_ext":
        raw = bytes([0x33]) * (BLOCK_SIZE * max(3, block_count))
        return PartitionSpec(
            "system_ext", raw,
            Operation("REPLACE_BZ", [Extent(0, max(3, block_count))], bz2.compress(raw)),
        )

    if name == "product":
        raw = random_bytes(rnd, BLOCK_SIZE * block_count)
        return PartitionSpec("product", raw, Operation("ZSTD", [Extent(0, block_count)], zstd_compress(raw)))

    if name == "vbmeta":
        raw = bytes(BLOCK_SIZE)
        return PartitionSpec("vbmeta", raw, Operation("ZERO", [Extent(0, 1)], b""))

    op_type = ("REPLACE", "REPLACE_XZ", "REPLACE_BZ", "ZSTD", "ZERO")[idx % 5]
    if op_type == "ZERO":
        raw = bytes(BLOCK_SIZE * block_count)
        return PartitionSpec(name, raw, Operation("ZERO", [Extent(0, block_count)], b""))

    raw = semi_random_bytes(rnd, BLOCK_SIZE * block_count) if op_type != "ZSTD" else random_bytes(rnd, BLOCK_SIZE * block_count)
    extents = [Extent(0, block_count)]

    if op_type == "REPLACE":
        blob = raw
    elif op_type == "REPLACE_XZ":
        blob = lzma.compress(raw, format=lzma.FORMAT_XZ)
    elif op_type == "REPLACE_BZ":
        blob = bz2.compress(raw)
    else:
        blob = zstd_compress(raw)
        op_type = "ZSTD"

    return PartitionSpec(name, raw, Operation(op_type, extents, blob))


def generate_specs(seed: int, total_mb: int) -> list[PartitionSpec]:
    rnd = random.Random(seed)
    fixed_blocks = {"boot": 3, "vendor_boot": 2, "system_ext": 3, "vbmeta": 1}
    target_blocks = (total_mb * 1024 * 1024) // BLOCK_SIZE
    special_min = sum(fixed_blocks.get(name, 0) for name in SPECIAL_PARTITIONS)
    remaining = target_blocks - special_min
    other_count = len(ALL_PARTITIONS) - len(SPECIAL_PARTITIONS)
    base_blocks = max(1, remaining // other_count)
    extra = remaining - base_blocks * other_count

    specs: list[PartitionSpec] = []
    for idx, name in enumerate(ALL_PARTITIONS):
        blocks = fixed_blocks[name] if name in fixed_blocks else base_blocks + (1 if idx < extra else 0)
        specs.append(make_partition_spec(name, idx, rnd, blocks))
    return specs


def build_base_artifacts(seed: int, total_mb: int) -> SampleArtifacts:
    specs = generate_specs(seed, total_mb)
    manifest_text, blobs = build_manifest_text(specs)

    pb2 = load_update_metadata_pb2(PROTO_DIR)
    manifest = pb2.DeltaArchiveManifest()
    from google.protobuf import text_format
    text_format.Parse(manifest_text, manifest)
    manifest_bin = manifest.SerializeToString()

    signatures_bin = b""
    payload_bytes = build_payload_bytes(manifest_bin, blobs, signatures_bytes=signatures_bin)
    metadata_bytes = payload_metadata_blob(manifest_bin, signatures_bin)
    payload_properties = build_payload_properties(payload_bytes, metadata_bytes)
    return SampleArtifacts(
        specs=specs,
        manifest_text=manifest_text,
        manifest_bin=manifest_bin,
        signatures_bin=signatures_bin,
        blobs=blobs,
        payload_bytes=payload_bytes,
        payload_properties=payload_properties,
        ota_payload_bytes=payload_bytes,
        ota_payload_properties=payload_properties,
        ota_has_payload=True,
        expected_error=None,
        scenario_notes=["baseline sample"],
    )


def _corrupt_payload_magic(payload_bytes: bytes) -> bytes:
    mutated = bytearray(payload_bytes)
    mutated[0:4] = b"BAD!"
    return bytes(mutated)


def _replace_payload_version(payload_bytes: bytes, version: int) -> bytes:
    mutated = bytearray(payload_bytes)
    mutated[4:12] = version.to_bytes(8, "big")
    return bytes(mutated)


def _truncate_payload_bytes(payload_bytes: bytes) -> bytes:
    truncate_by = min(max(64, len(payload_bytes) // 8), 4096)
    if truncate_by >= len(payload_bytes):
        truncate_by = max(1, len(payload_bytes) - 1)
    return payload_bytes[:-truncate_by]


def _corrupt_first_blob_byte(base: SampleArtifacts) -> bytes:
    if not base.blobs:
        raise RuntimeError("checksum_mismatch scenario requires at least one operation blob")
    payload_bytes = bytearray(base.payload_bytes)
    data_offset = 24 + len(base.manifest_bin) + len(base.signatures_bin)
    payload_bytes[data_offset] ^= 0xFF
    return bytes(payload_bytes)


def apply_scenario(base: SampleArtifacts, scenario: str) -> SampleArtifacts:
    if scenario == DEFAULT_SCENARIO:
        return base

    payload_bytes = base.payload_bytes
    manifest_text = base.manifest_text
    manifest_bin = base.manifest_bin
    signatures_bin = base.signatures_bin
    ota_payload_bytes = base.payload_bytes
    ota_has_payload = True
    notes = [SCENARIOS[scenario].description]

    if scenario == "invalid_magic":
        payload_bytes = _corrupt_payload_magic(base.payload_bytes)
        ota_payload_bytes = payload_bytes
    elif scenario == "unsupported_version":
        payload_bytes = _replace_payload_version(base.payload_bytes, 3)
        ota_payload_bytes = payload_bytes
    elif scenario == "truncated_payload":
        payload_bytes = _truncate_payload_bytes(base.payload_bytes)
        ota_payload_bytes = payload_bytes
    elif scenario == "checksum_mismatch":
        payload_bytes = _corrupt_first_blob_byte(base)
        ota_payload_bytes = payload_bytes
    elif scenario == "invalid_partition_name":
        unsafe_name = "../evil_boot"
        manifest_text = base.manifest_text.replace('partition_name: "abl"', f'partition_name: "{unsafe_name}"', 1)
        from google.protobuf import text_format
        pb2 = load_update_metadata_pb2(PROTO_DIR)
        manifest = pb2.DeltaArchiveManifest()
        text_format.Parse(manifest_text, manifest)
        manifest_bin = manifest.SerializeToString()
        payload_bytes = build_payload_bytes(manifest_bin, base.blobs, signatures_bytes=signatures_bin)
        ota_payload_bytes = payload_bytes
        notes.append(f"first partition renamed to {unsafe_name!r}")
    elif scenario == "missing_payload_in_zip":
        ota_has_payload = False
        notes.append("raw payload.bin remains valid; ota_update.zip is the negative fixture")
    elif scenario == "corrupt_zip_payload":
        ota_payload_bytes = _corrupt_payload_magic(base.payload_bytes)
        notes.append("raw payload.bin remains valid; ota_update.zip embeds the corrupted payload")
    else:
        raise ValueError(f"unsupported scenario: {scenario}")

    metadata_bytes = payload_metadata_blob(manifest_bin, signatures_bin)
    payload_properties = build_payload_properties(payload_bytes, metadata_bytes)
    ota_payload_properties = build_payload_properties(ota_payload_bytes, metadata_bytes)

    return SampleArtifacts(
        specs=base.specs,
        manifest_text=manifest_text,
        manifest_bin=manifest_bin,
        signatures_bin=signatures_bin,
        blobs=base.blobs,
        payload_bytes=payload_bytes,
        payload_properties=payload_properties,
        ota_payload_bytes=ota_payload_bytes,
        ota_payload_properties=ota_payload_properties,
        ota_has_payload=ota_has_payload,
        expected_error=SCENARIOS[scenario].expected_error,
        scenario_notes=notes,
    )


def write_sample_bundle(
    sample_root: Path,
    artifacts: SampleArtifacts,
    scenario: str,
    seed: int,
) -> None:
    scenario_lines = [
        f"name={sample_root.name}",
        f"scenario={scenario}",
        f"seed={seed}",
        f"description={SCENARIOS[scenario].description}",
        *(f"note={note}" for note in artifacts.scenario_notes),
    ]
    expected_text = "success\n" if artifacts.expected_error is None else f"error[{artifacts.expected_error}]\n"

    write_bundle(
        sample_root,
        specs=artifacts.specs,
        payload_bytes=artifacts.ota_payload_bytes,
        payload_properties=artifacts.ota_payload_properties,
        manifest_text=artifacts.manifest_text,
        scenario_lines=scenario_lines,
        expected_text=expected_text,
        include_payload=artifacts.ota_has_payload,
    )

    print(f"[INFO] scenario: {scenario}")
    print(f"[INFO] expected: {expected_text.strip()}")
    print(f"[INFO] seed: {seed}")
    print(f"[INFO] manifest text: {sample_root / 'manifest.textproto'}")
    print(f"[INFO] payload size: {(sample_root / 'payload.bin').stat().st_size:,} bytes")
    print(f"[INFO] raw partition total: {sum(len(spec.img) for spec in artifacts.specs):,} bytes")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-root", default="tests/data/generated", help="output root relative to repo root")
    parser.add_argument("--name", default="sample", help="sample name")
    parser.add_argument("--seed", type=int, default=None, help="random seed for reproducibility")
    parser.add_argument("--total-mb", type=int, default=128, help="target raw partition size in MB")
    parser.add_argument("--scenario", default=DEFAULT_SCENARIO, choices=[*SCENARIOS.keys(), "all"], help="fixture scenario to generate")
    parser.add_argument("--list-scenarios", action="store_true", help="print available scenarios and exit")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.list_scenarios:
        for name, definition in SCENARIOS.items():
            expected = definition.expected_error or "success"
            print(f"{name:20s} {expected:28s} {definition.description}")
        return 0

    out_root = (REPO_ROOT / args.out_root).resolve()
    out_root.mkdir(parents=True, exist_ok=True)

    seed = args.seed
    if seed is None:
        seed = (time.time_ns() ^ os.getpid() ^ int.from_bytes(os.urandom(8), "little")) & ((1 << 63) - 1)

    base = build_base_artifacts(seed, args.total_mb)
    scenarios = list(SCENARIOS.keys()) if args.scenario == "all" else [args.scenario]
    for scenario in scenarios:
        sample_name = args.name if args.scenario != "all" else f"{args.name}-{scenario}"
        write_sample_bundle(out_root / sample_name, apply_scenario(base, scenario), scenario, seed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
