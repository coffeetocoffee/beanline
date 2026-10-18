#!/usr/bin/env bash
# Generate a CycloneDX SBOM for the release artifact.
#
#   ./scripts/sbom.sh <binary> <output.json> [version]
#
# Beanline vendors no third-party packages: the library, the Postgres wire
# protocol, the RESP client, and the HTTP server are all first-party or
# std-only. The SBOM therefore lists the artifact itself plus the components
# that actually ship with it, and records the SHA-256 of the binary so a
# consumer can verify what the SBOM describes.
set -euo pipefail

BINARY="${1:-zig-out/bin/beanline}"
OUT="${2:-dist/beanline.sbom.json}"
VERSION="${3:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"

[ -f "$BINARY" ] || { echo "no binary at $BINARY" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

SHA=$(sha256sum "$BINARY" | awk '{print $1}')
SIZE=$(wc -c < "$BINARY" | tr -d ' ')
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$OUT" <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:$(python -c 'import uuid;print(uuid.uuid4())' 2>/dev/null || echo 00000000-0000-4000-8000-000000000000)",
  "version": 1,
  "metadata": {
    "timestamp": "$TIMESTAMP",
    "tools": [{ "vendor": "beanline", "name": "scripts/sbom.sh" }],
    "component": {
      "type": "application",
      "name": "beanline",
      "version": "$VERSION",
      "purl": "pkg:generic/beanline@$VERSION"
    }
  },
  "components": [
    {
      "type": "library",
      "name": "zig-std",
      "version": "0.14.1",
      "scope": "required",
      "purl": "pkg:generic/zig-std@0.14.1",
      "description": "Zig standard library, statically linked."
    }
  ],
  "hashes": [
    {
      "alg": "SHA-256",
      "content": "$SHA"
    }
  ],
  "properties": [
    { "name": "beanline:artifact_size_bytes", "value": "$SIZE" },
    { "name": "beanline:vendored_dependencies", "value": "none" }
  ]
}
EOF

echo "==> wrote $OUT (sha256 $SHA)"
