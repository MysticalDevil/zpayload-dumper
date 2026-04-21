#!/usr/bin/env bash
# Generic release build: both architectures via Docker.
#
# Works on any machine with Docker (including qemu-user-static for arm64).
# Warning: aarch64 build compiles protobuf from source under qemu emulation,
# which is very slow (~30+ minutes on a typical desktop).
#
# Usage: ./scripts/build-release.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/release"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "=== Building x86_64 (Docker) ==="
cd "$ROOT"
docker build --network host --platform linux/amd64 -t zpayload-builder:x86_64 .
CID=$(docker create zpayload-builder:x86_64)
docker cp "$CID":/src/zig-out/bin/zpayload-dumper "$OUT/zpayload-dumper-linux-x86_64"
docker rm "$CID"

echo "=== Building aarch64 (Docker + qemu) ==="
cd "$ROOT"
docker build --network host --platform linux/arm64 -t zpayload-builder:aarch64 .
CID=$(docker create zpayload-builder:aarch64)
docker cp "$CID":/src/zig-out/bin/zpayload-dumper "$OUT/zpayload-dumper-linux-aarch64"
docker rm "$CID"

echo "=== Checksums ==="
cd "$OUT"
sha256sum zpayload-dumper-linux-* > SHA256SUMS
cat SHA256SUMS

echo ""
echo "Done. Artifacts in $OUT/"
echo "Manual release step: gh release create <tag> $OUT/*"
