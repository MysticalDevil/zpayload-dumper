"""Utility functions for payload generation."""

from __future__ import annotations

import random
import subprocess


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


def pad_block_aligned(data: bytes, block_size: int) -> bytes:
    remainder = len(data) % block_size
    if remainder == 0:
        return data
    return data + b"\x00" * (block_size - remainder)
