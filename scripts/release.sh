#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/release"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "=== Building x86_64 ==="
cd "$ROOT"
zig build -Doptimize=ReleaseFast
cp zig-out/bin/zpayload-dumper "$OUT/zpayload-dumper-linux-x86_64"

echo "=== Building aarch64 (Docker) ==="
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
