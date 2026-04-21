#!/usr/bin/env bash
# Native-optimized release build for Gentoo hosts with crossdev.
#
# - x86_64: compiled natively (fast)
# - aarch64: compiled inside an arm64 Docker container that reuses the host's
#   Gentoo crossdev sysroot for protobuf/upb libraries. No qemu compilation of
#   protobuf needed.
#
# Prerequisites on host:
#   sudo aarch64-unknown-linux-gnu-emerge dev-libs protobuf app-arch/bzip2
#
# Usage: ./scripts/build-release-native.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/release"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "=== Building x86_64 (native) ==="
cd "$ROOT"
zig build -Doptimize=ReleaseFast
cp zig-out/bin/zpayload-dumper "$OUT/zpayload-dumper-linux-x86_64"

echo "=== Building aarch64 (Docker + crossdev sysroot) ==="
cd "$ROOT"
docker build --network host --platform linux/arm64 -f Dockerfile.aarch64 -t zpayload-builder:aarch64 .
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
