#!/usr/bin/env bash
# Run pgbench in a SEPARATE database (benchdb) to test the CPU/memory limits. appdb is not touched.
#   CLIENTS=8 DURATION=30 SCALE=3 ./scripts/load-test.sh      Evidence: evidence/load-test.log
set -Eeuo pipefail
NS=postgres; POD=postgres-0; DB=benchdb
CLIENTS="${CLIENTS:-8}"; DURATION="${DURATION:-30}"; SCALE="${SCALE:-3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/evidence/load-test.log"; mkdir -p "$ROOT/evidence"; : > "$OUT"
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$OUT"; }
pg()  { kubectl -n "$NS" exec "$POD" -- "$@"; }
restarts() { kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}'; }
# CPU-limit throttling counters from the container's cgroup (cumulative since the container started)
thr() { pg sh -c "grep -E 'nr_throttled|throttled_usec' /sys/fs/cgroup/cpu.stat" 2>/dev/null | tr '\n' ' ' || true; }
trap 'log "RESULT: FAIL - command failed at line $LINENO"' ERR

R0=$(restarts)
log "limits/requests: $(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].resources}')"
log "restarts before: $R0"
log "cpu throttling before: $(thr)"
pg psql -U postgres -d postgres -qc "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -qc "CREATE DATABASE $DB"
pg pgbench -U postgres -i -q -s "$SCALE" "$DB" 2>&1 | tee -a "$OUT"
( sleep $((DURATION*4/5)); echo "$(date +%T) kubectl top (late in run; metrics can lag): $(kubectl -n "$NS" top pod "$POD" --no-headers 2>&1 || true)" >> "$OUT" ) &
log "running pgbench: $CLIENTS clients for ${DURATION}s"
pg pgbench -U postgres -c "$CLIENTS" -j 2 -T "$DURATION" -P 10 "$DB" 2>&1 | tee -a "$OUT"
wait
ROWS=$(pg psql -U postgres -d "$DB" -tAc "SELECT count(*) FROM pgbench_accounts")
R1=$(restarts)
REASON=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}')
log "cpu throttling after: $(thr)"
log "pgbench_accounts rows: $ROWS (expected $((100000*SCALE))) | restarts after: $R1 | last termination reason: ${REASON:-none}"
pg psql -U postgres -d postgres -qc "DROP DATABASE IF EXISTS $DB WITH (FORCE)"
trap - ERR
[ "$R0" = "$R1" ] && [ "$ROWS" = "$((100000*SCALE))" ] && [ "$REASON" != "OOMKilled" ] \
  && log "RESULT: PASS - database stayed within its limits (no restart, no OOMKill, data complete)" \
  || { log "RESULT: FAIL - restart, OOMKill or missing rows during load"; exit 1; }
