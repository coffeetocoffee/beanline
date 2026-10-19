#!/usr/bin/env bash
# Build release artifacts for every supported target, then checksum them.
#
#   ./scripts/release.sh [version]
#
# The version defaults to the current git tag (or "dev"). Output lands in
# dist/ as .tar.gz for unix targets and .zip for Windows.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
OUT="dist"
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"

rm -rf "$OUT"
mkdir -p "$OUT"

build() {
  local target="$1"
  local name="$2"
  echo "==> building $name ($target)"
  zig build -Doptimize="$OPTIMIZE" -Dtarget="$target" --prefix "$OUT/$name"
  if [ "$name" = "windows-x86_64" ]; then
    (cd "$OUT/$name" && zip -qr "../beanline-$VERSION-$name.zip" .)
    rm -rf "$OUT/$name"
  else
    tar -C "$OUT/$name" -czf "$OUT/beanline-$VERSION-$name.tar.gz" .
    rm -rf "$OUT/$name"
  fi
}

build x86_64-linux-musl    linux-x86_64
build aarch64-linux-musl   linux-aarch64
build x86_64-macos         macos-aarch64
build x86_64-windows       windows-x86_64

# SBOM for the linux artifact, generated from the binary that is shipped.
mkdir -p "$OUT/sbom"
zig build -Doptimize="$OPTIMIZE" -Dtarget=x86_64-linux-musl --prefix "$OUT/sbom"
bash scripts/sbom.sh "$OUT/sbom/bin/beanline" "$OUT/beanline.sbom.json" "$VERSION"

cp Dockerfile README.md LICENSE "$OUT/" 2>/dev/null || true

(cd "$OUT" && sha256sum ./*.tar.gz ./*.zip > SHA256SUMS 2>/dev/null || shasum -a 256 ./*.tar.gz ./*.zip > SHA256SUMS)

echo "==> artifacts in $OUT:"
ls -1 "$OUT"
cat "$OUT/SHA256SUMS"
