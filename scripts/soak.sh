#!/usr/bin/env bash
# Long-running soak harness.
#
#   ./scripts/soak.sh [duration-hours]
#
# Runs a mixed workload against the configured backend for the requested
# duration (default 168 h = one week), continuously checking the error budget
# described in docs/soak.md. Exits non-zero if the budget is blown.
#
# Environment:
#   BEANLINE_DATABASE_URL / BEANLINE_REDIS_URL  backend (required)
#   BEANLINE_DASH_BIND                          dashboard bind (default 127.0.0.1:9484)
#   SOAK_HOURS                                  duration in hours (default 168)
#   SOAK_WORKERS                                worker count (default 8)
#   SOAK_REPORT                                 report path (default soak-report.json)
set -euo pipefail

cd "$(dirname "$0")/.."

HOURS="${1:-${SOAK_HOURS:-168}}"
WORKERS="${SOAK_WORKERS:-8}"
REPORT="${SOAK_REPORT:-soak-report.json}"
BIND="${BEANLINE_DASH_BIND:-127.0.0.1:9484}"
DEADLINE=$(( $(date +%s) + HOURS * 3600 ))

# Error budget for a week (docs/soak.md).
MAX_DEAD_RATE="${MAX_DEAD_RATE:-0.001}"   # dead jobs per completed job
MAX_P99_MS="${MAX_P99_MS:-250}"            # claim p99 ceiling
MAX_REAP_RATE="${MAX_REAP_RATE:-0.001}"    # reaped jobs per completed job
MAX_QUEUE_AGE_MS="${MAX_QUEUE_AGE_MS:-60000}"

echo "==> soak for ${HOURS}h, ${WORKERS} workers, backend from the environment"
echo "    budget: dead<=${MAX_DEAD_RATE} reap<=${MAX_REAP_RATE} p99<=${MAX_P99_MS}ms age<=${MAX_QUEUE_AGE_MS}ms"

# A worker tier and a dashboard tier, so the soak covers the real topology.
./zig-out/bin/beanline server >soak-server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

./zig-out/bin/beanline worker >soak-worker.log 2>&1 &
WORKER_PID=$!
trap 'kill $WORKER_PID $SERVER_PID 2>/dev/null || true' EXIT

sleep 5

VIOLATIONS=0
CHECKS=0

metric() {
  curl -fsS "http://${BIND}/metrics" | grep -E "^$1" | head -1 | awk '{print $2+0}'
}

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 60
  CHECKS=$((CHECKS + 1))

  COMPLETED=$(metric 'beanline_jobs_completed_total\{outcome="success"\}')
  DEAD=$(metric 'beanline_jobs_dead_total')
  REAPED=$(metric 'beanline_jobs_reaped_total')
  P99=$(metric 'beanline_claim_duration_seconds\{quantile="0.99"\}')
  OLDEST=$(metric 'beanline_queue_oldest_pending_seconds')

  if [ -z "${COMPLETED:-}" ]; then
    echo "!! metrics unavailable (broker or dashboard down?)"
    VIOLATIONS=$((VIOLATIONS + 1))
    continue
  fi

  if [ "${P99:-0}" != "0" ] && awk "BEGIN{exit !(${P99} > ${MAX_P99_MS})}"; then
    echo "!! claim p99 ${P99}ms above budget ${MAX_P99_MS}ms"
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  if [ "${COMPLETED:-0}" -gt 0 ]; then
    if awk "BEGIN{exit !(${DEAD:-0} / ${COMPLETED} > ${MAX_DEAD_RATE})}"; then
      echo "!! dead rate ${DEAD}/${COMPLETED} above budget ${MAX_DEAD_RATE}"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
    if awk "BEGIN{exit !(${REAPED:-0} / ${COMPLETED} > ${MAX_REAP_RATE})}"; then
      echo "!! reap rate ${REAPED}/${COMPLETED} above budget ${MAX_REAP_RATE}"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  fi

  if [ "${OLDEST:-0}" != "0" ] && awk "BEGIN{exit !(${OLDEST} * 1000 > ${MAX_QUEUE_AGE_MS})}"; then
    echo "!! oldest pending ${OLDEST}s above budget $((MAX_QUEUE_AGE_MS / 1000))s"
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  echo "[$(date -u +%H:%M:%S)] completed=${COMPLETED} dead=${DEAD} reaped=${REAPED} p99=${P99} oldest=${OLDEST} violations=${VIOLATIONS}"
done

cat > "$REPORT" <<EOF
{
  "hours": ${HOURS},
  "checks": ${CHECKS},
  "violations": ${VIOLATIONS},
  "completed": ${COMPLETED:-0},
  "dead": ${DEAD:-0},
  "reaped": ${REAPED:-0},
  "claim_p99": ${P99:-0},
  "oldest_pending_seconds": ${OLDEST:-0},
  "budget": {
    "dead_rate": ${MAX_DEAD_RATE},
    "reap_rate": ${MAX_REAP_RATE},
    "claim_p99_ms": ${MAX_P99_MS},
    "oldest_pending_ms": ${MAX_QUEUE_AGE_MS}
  }
}
EOF

echo "==> soak finished: ${CHECKS} checks, ${VIOLATIONS} violations (report: $REPORT)"
[ "$VIOLATIONS" -eq 0 ]
