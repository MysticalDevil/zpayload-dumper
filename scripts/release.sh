#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 v0.3.0"
    exit 1
fi

REPO="MysticalDevil/zpayload-dumper"
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

echo "=== Creating GitHub release $VERSION ==="
gh release create "$VERSION" \
    --repo "$REPO" \
    --title "$VERSION" \
    --generate-notes \
    --verify-tag \
    zpayload-dumper-linux-x86_64 \
    zpayload-dumper-linux-aarch64 \
    SHA256SUMS

echo "Done: https://github.com/$REPO/releases/tag/$VERSION"
