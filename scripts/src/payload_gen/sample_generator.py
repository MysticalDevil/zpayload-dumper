"""Generate synthetic valid and invalid payload/OTA fixtures for tests."""

from __future__ import annotations

import argparse
import bz2
import hashlib
import lzma
import os
import random
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from payload_gen.payload_format import (
    build_payload_bytes,
    build_payload_properties,
    payload_metadata_blob,
    write_ota_tar,
    write_ota_zip,
    write_payload_file,
)
from payload_gen.project import PROTO_DIR, REPO_ROOT

BLOCK_SIZE = 4096
DEFAULT_SCENARIO = "valid"
ALL_PARTITIONS = [
    "abl",
    "bl31",
    "gsa",
    "modem",
    "pvmfw",
    "system",
    "vbmeta_system",
    "vendor_dlkm",
    "bl1",
    "boot",
    "init_boot",
    "pbl",
    "system_dlkm",
    "tzsw",
    "vbmeta_vendor",
    "vendor",
    "bl2",
    "dtbo",
    "ldfw",
    "product",
    "system_ext",
    "vbmeta",
    "vendor_boot",
    "vendor_kernel_boot",
]
SPECIAL_PARTITIONS = {"boot", "vendor_boot", "system_ext", "product", "vbmeta"}


@dataclass(frozen=True)
class ScenarioDefinition:
    description: str
    expected_error: str | None


SCENARIOS = {
    "valid": ScenarioDefinition(
        description="Well-formed payload.bin and OTA zip.",
        expected_error=None,
    ),
    "invalid_magic": ScenarioDefinition(
        description="Corrupt payload magic so header parse fails immediately.",
        expected_error="invalid_magic",
    ),
    "unsupported_version": ScenarioDefinition(
        description="Use payload version 3 instead of 2.",
        expected_error="unsupported_payload_version",
    ),
    "truncated_payload": ScenarioDefinition(
        description="Cut payload.bin short after metadata/data begins.",
        expected_error="io_failure",
    ),
    "checksum_mismatch": ScenarioDefinition(
        description="Corrupt one operation blob byte without updating manifest hashes.",
        expected_error="checksum_mismatch",
    ),
    "invalid_partition_name": ScenarioDefinition(
        description="Encode an unsafe partition name such as ../evil.",
        expected_error="invalid_partition_name",
    ),
    "missing_payload_in_zip": ScenarioDefinition(
        description="Create a valid OTA zip without payload.bin.",
        expected_error="payload_not_found_in_zip",
    ),
    "corrupt_zip_payload": ScenarioDefinition(
        description="Keep payload.bin valid on disk but corrupt the copy embedded in ota_update.zip.",
        expected_error="invalid_magic",
    ),
}


@dataclass
class Extent:
    start_block: int
    num_blocks: int


@dataclass
class Operation:
    op_type: str
    extents: list[Extent]
    blob: bytes

    @property
    def dst_length(self) -> int:
        return sum(e.num_blocks for e in self.extents) * BLOCK_SIZE


@dataclass
class PartitionSpec:
    name: str
    img: bytes
    op: Operation


@dataclass
class SampleArtifacts:
    specs: list[PartitionSpec]
    manifest_text: str
    manifest_bin: bytes
    signatures_bin: bytes
    blobs: bytes
    payload_bytes: bytes
    payload_properties: bytes
    ota_payload_bytes: bytes
    ota_payload_properties: bytes
    ota_has_payload: bool
    expected_error: str | None
    scenario_notes: list[str]


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


def make_scattered_image(pattern_a: int, pattern_b: int) -> tuple[bytes, list[Extent], bytes]:
    blk_a = bytes([pattern_a]) * BLOCK_SIZE
    blk_b = bytes([pattern_b]) * BLOCK_SIZE
    img = bytearray(BLOCK_SIZE * 3)
    img[0:BLOCK_SIZE] = blk_a
    img[BLOCK_SIZE * 2 : BLOCK_SIZE * 3] = blk_b
    return bytes(img), [Extent(0, 1), Extent(2, 1)], blk_a + blk_b


def random_bytes(rnd: random.Random, length: int) -> bytes:
    return bytes(rnd.randrange(0, 256) for _ in range(length))


def semi_random_bytes(rnd: random.Random, length: int) -> bytes:
    buf = bytearray(length)
    chunk = bytes(rnd.randrange(0, 256) for _ in range(1024))
    for i in range(0, length, 1024):
        end = min(i + 1024, length)
        if rnd.random() < 0.1:
            chunk = bytes(rnd.randrange(0, 256) for _ in range(1024))
        buf[i:end] = chunk[: end - i]
    return bytes(buf)


def make_partition_spec(name: str, idx: int, rnd: random.Random, block_count: int) -> PartitionSpec:
    if name == "boot":
        boot_img, boot_extents, boot_raw = make_scattered_image(0x41, 0x42)
        return PartitionSpec("boot", boot_img, Operation("REPLACE", boot_extents, boot_raw))

    if name == "vendor_boot":
        raw = bytes([0x56]) * (BLOCK_SIZE * max(2, block_count))
        return PartitionSpec(
            "vendor_boot",
            raw,
            Operation("REPLACE_XZ", [Extent(0, max(2, block_count))], lzma.compress(raw, format=lzma.FORMAT_XZ)),
        )

    if name == "system_ext":
        raw = bytes([0x33]) * (BLOCK_SIZE * max(3, block_count))
        return PartitionSpec(
            "system_ext",
            raw,
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


def bytes_to_proto_string(blob: bytes) -> str:
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
            lines.append(f"    data_sha256_hash: {bytes_to_proto_string(data_sha)}")
        lines.append("  }")
        lines.append("}")
        data_blob.extend(op.blob)
        cur_off += len(op.blob)

    return "\n".join(lines) + "\n", bytes(data_blob)


def protoc_encode_manifest(proto_path: Path, text: str) -> bytes:
    proc = subprocess.run(
        [
            "protoc",
            f"--proto_path={proto_path.parent}",
            "--encode=chromeos_update_engine.DeltaArchiveManifest",
            str(proto_path.name),
        ],
        input=text.encode(),
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"protoc manifest encode failed: rc={proc.returncode}, stderr={proc.stderr.decode(errors='ignore')}"
        )
    return proc.stdout


def build_base_artifacts(seed: int, total_mb: int) -> SampleArtifacts:
    specs = generate_specs(seed, total_mb)
    manifest_text, blobs = build_manifest_text(specs)
    manifest_bin = protoc_encode_manifest(PROTO_DIR / "update_metadata.proto", manifest_text)
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


def replace_payload_version(payload_bytes: bytes, version: int) -> bytes:
    mutated = bytearray(payload_bytes)
    mutated[4:12] = version.to_bytes(8, "big")
    return bytes(mutated)


def corrupt_payload_magic(payload_bytes: bytes) -> bytes:
    mutated = bytearray(payload_bytes)
    mutated[0:4] = b"BAD!"
    return bytes(mutated)


def truncate_payload_bytes(payload_bytes: bytes) -> bytes:
    truncate_by = min(max(64, len(payload_bytes) // 8), 4096)
    if truncate_by >= len(payload_bytes):
        truncate_by = max(1, len(payload_bytes) - 1)
    return payload_bytes[:-truncate_by]


def corrupt_first_blob_byte(base: SampleArtifacts) -> bytes:
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
        payload_bytes = corrupt_payload_magic(base.payload_bytes)
        ota_payload_bytes = payload_bytes
    elif scenario == "unsupported_version":
        payload_bytes = replace_payload_version(base.payload_bytes, 3)
        ota_payload_bytes = payload_bytes
    elif scenario == "truncated_payload":
        payload_bytes = truncate_payload_bytes(base.payload_bytes)
        ota_payload_bytes = payload_bytes
    elif scenario == "checksum_mismatch":
        payload_bytes = corrupt_first_blob_byte(base)
        ota_payload_bytes = payload_bytes
    elif scenario == "invalid_partition_name":
        unsafe_name = "../evil_boot"
        manifest_text = base.manifest_text.replace('partition_name: "abl"', f'partition_name: "{unsafe_name}"', 1)
        manifest_bin = protoc_encode_manifest(PROTO_DIR / "update_metadata.proto", manifest_text)
        payload_bytes = build_payload_bytes(manifest_bin, base.blobs, signatures_bytes=signatures_bin)
        ota_payload_bytes = payload_bytes
        notes.append(f"first partition renamed to {unsafe_name!r}")
    elif scenario == "missing_payload_in_zip":
        ota_has_payload = False
        notes.append("raw payload.bin remains valid; ota_update.zip is the negative fixture")
    elif scenario == "corrupt_zip_payload":
        ota_payload_bytes = corrupt_payload_magic(base.payload_bytes)
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


def write_sample_bundle(sample_root: Path, artifacts: SampleArtifacts, scenario: str, seed: int) -> None:
    payload_path = sample_root / "payload.bin"
    ota_zip_path = sample_root / "ota_update.zip"
    ota_tar_path = sample_root / "ota_update.tar"
    ota_tgz_path = sample_root / "ota_update.tar.gz"
    extracted_dir = sample_root / "extracted"
    manifest_txt_path = sample_root / "manifest.textproto"
    scenario_txt_path = sample_root / "scenario.txt"
    expected_txt_path = sample_root / "expected_result.txt"

    if sample_root.exists():
        shutil.rmtree(sample_root)
    extracted_dir.mkdir(parents=True, exist_ok=True)

    manifest_txt_path.write_text(artifacts.manifest_text)
    write_payload_file(payload_path, artifacts.payload_bytes)
    write_ota_zip(
        ota_zip_path,
        payload_bytes=artifacts.ota_payload_bytes,
        payload_properties=artifacts.ota_payload_properties,
        include_payload=artifacts.ota_has_payload,
    )
    write_ota_tar(
        ota_tar_path,
        payload_bytes=artifacts.ota_payload_bytes,
        payload_properties=artifacts.ota_payload_properties,
        include_payload=artifacts.ota_has_payload,
        compress=False,
    )
    write_ota_tar(
        ota_tgz_path,
        payload_bytes=artifacts.ota_payload_bytes,
        payload_properties=artifacts.ota_payload_properties,
        include_payload=artifacts.ota_has_payload,
        compress=True,
    )

    for spec in artifacts.specs:
        (extracted_dir / f"{spec.name}.img").write_bytes(spec.img)

    scenario_lines = [
        f"name={sample_root.name}",
        f"scenario={scenario}",
        f"seed={seed}",
        f"description={SCENARIOS[scenario].description}",
        *(f"note={note}" for note in artifacts.scenario_notes),
    ]
    scenario_txt_path.write_text("\n".join(scenario_lines) + "\n")

    expected_txt_path.write_text("success\n" if artifacts.expected_error is None else f"error[{artifacts.expected_error}]\n")

    print(f"[OK] generated payload: {payload_path}")
    print(f"[OK] generated ota zip: {ota_zip_path}")
    print(f"[OK] generated ota tar: {ota_tar_path}")
    print(f"[OK] generated ota tgz: {ota_tgz_path}")
    print(f"[OK] generated golden dir: {extracted_dir}")
    print(f"[INFO] scenario: {scenario}")
    print(f"[INFO] expected: {expected_txt_path.read_text().strip()}")
    print(f"[INFO] seed: {seed}")
    print(f"[INFO] manifest text: {manifest_txt_path}")
    print(f"[INFO] payload size: {payload_path.stat().st_size:,} bytes")
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
