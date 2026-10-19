#!/usr/bin/env bash
# Regenerate the benchmark reference files.
#
#   ./scripts/bench-reference.sh [backend-url-env]
#
# Run this on the machine that is the reference (same hardware, same database
# config, same container limits) and commit the result. The nightly CI job
# compares against these files and fails on a p99 regression above 5%.
set -euo pipefail

cd "$(dirname "$0")/.."

WORKLOADS="${WORKLOADS:-noop io cpu flaky poison}"
WORKERS="${WORKERS:-8}"
QUEUES="${QUEUES:-2}"
DURATION="${DURATION:-120}"
WARMUP="${WARMUP:-10}"
OUT="${OUT:-bench/reference}"

mkdir -p "$OUT"

for workload in $WORKLOADS; do
  echo "==> $workload"
  ./zig-out/bin/beanline bench \
    --workload "$workload" \
    --duration "$DURATION" \
    --warmup "$WARMUP" \
    --workers "$WORKERS" \
    --queues "$QUEUES" \
    --report "$OUT/.tmp-$workload.json"

  # The report is named by the backend it ran against.
  backend="$(sed -n 's/.*"backend": "\([^"]*\)".*/\1/p' "$OUT/.tmp-$workload.json")"
  mv "$OUT/.tmp-$workload.json" "$OUT/$backend-$workload.json"
  echo "    -> $OUT/$backend-$workload.json"
done

echo "==> done. Commit the regenerated references."
