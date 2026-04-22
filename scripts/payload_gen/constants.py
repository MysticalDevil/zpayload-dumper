"""Constants and scenario definitions for payload generation."""

from __future__ import annotations

from dataclasses import dataclass

BLOCK_SIZE = 4096
DEFAULT_SCENARIO = "valid"

ALL_PARTITIONS = [
    "abl", "bl31", "gsa", "modem", "pvmfw", "system", "vbmeta_system", "vendor_dlkm",
    "bl1", "boot", "init_boot", "pbl", "system_dlkm", "tzsw", "vbmeta_vendor", "vendor",
    "bl2", "dtbo", "ldfw", "product", "system_ext", "vbmeta", "vendor_boot", "vendor_kernel_boot",
]
SPECIAL_PARTITIONS = {"boot", "vendor_boot", "system_ext", "product", "vbmeta"}


@dataclass(frozen=True)
class ScenarioDefinition:
    description: str
    expected_error: str | None


SCENARIOS = {
    "valid": ScenarioDefinition(
        description="Well-formed payload.bin and OTA zip.", expected_error=None,
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
