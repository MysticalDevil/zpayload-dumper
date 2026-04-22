#!/usr/bin/env bash
# Generic release build via Docker for the current host architecture.
#
# Detects host architecture and builds natively (no qemu emulation).
# Protobuf is compiled from source inside the container.
#
# Usage: ./scripts/shell/build-release.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/release"
DOCKER_PREFIX="/opt/zpayload-install"

ARCH=$(uname -m)
DOCKER_ARCH=$([ "$ARCH" = "aarch64" ] && echo "linux/arm64" || echo "linux/amd64")
OUT_NAME=$([ "$ARCH" = "aarch64" ] && echo "zpayload-dumper-linux-aarch64" || echo "zpayload-dumper-linux-x86_64")

rm -rf "$OUT"
mkdir -p "$OUT"

echo "=== Building $ARCH (Docker, platform=$DOCKER_ARCH) ==="
cd "$ROOT"
docker build --network host --platform "$DOCKER_ARCH" -t zpayload-builder:release .
CID=$(docker create zpayload-builder:release)
docker cp "$CID":"$DOCKER_PREFIX/bin/zpayload-dumper" "$OUT/$OUT_NAME"
docker rm "$CID"

echo "=== Checksum ==="
cd "$OUT"
sha256sum "$OUT_NAME" > SHA256SUMS
cat SHA256SUMS

echo ""
echo "Done. Artifact in $OUT/"
echo "Manual release step: gh release create <tag> $OUT/*"
