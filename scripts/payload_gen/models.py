"""Data models for payload generation."""

from __future__ import annotations

from dataclasses import dataclass

from payload_gen.constants import BLOCK_SIZE


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
