#!/usr/bin/env bash
# Pod-deletion data test: write rows, delete the pod, confirm the SAME rows survive.
# Exits non-zero on any failure. Safe to re-run: each run tags its rows with a unique run id.
set -Eeuo pipefail

NS="${NS:-postgres}"; POD="${POD:-postgres-0}"; DB="${DB:-appdb}"
SVC_HOST="${SVC_HOST:-$POD.postgres.$NS.svc.cluster.local}"
TIMEOUT="${TIMEOUT:-180}"          # seconds to wait for the replacement pod
KEEP_ROWS="${KEEP_ROWS:-0}"        # 1 = leave this run's rows in the table
CHECK_DNS="${CHECK_DNS:-1}"        # 0 = skip the Service DNS check
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$SCRIPT_DIR/../evidence/data-test.log}"
mkdir -p "$(dirname "$OUT")"; : > "$OUT"
RUN_ID="$(date +%s)"

log()  { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$OUT"; }
fail() { log "RESULT: FAIL - $*"; exit 1; }
trap 'log "RESULT: FAIL - command failed (line $LINENO)"' ERR

q()   { kubectl -n "$NS" exec "$POD" -- psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -tA -c "$1"; }
uid() { kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}'; }
pvc() { kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.volumes[?(@.name=="pgdata")].persistentVolumeClaim.claimName}'; }

log "=== run $RUN_ID (ns=$NS pod=$POD db=$DB) ==="
log "STEP 0: preflight"
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=60s >/dev/null || fail "$POD is not Ready before the test"

log "STEP 1: create table and insert rows"
q "CREATE TABLE IF NOT EXISTS inventory (id serial PRIMARY KEY, sku text, qty int);" >/dev/null
q "ALTER TABLE inventory ADD COLUMN IF NOT EXISTS run_id bigint;" >/dev/null
q "INSERT INTO inventory (sku, qty, run_id) VALUES ('LAP-001',42,$RUN_ID),('MOU-002',310,$RUN_ID),('KEY-003',128,$RUN_ID);" >/dev/null
ROWS_SQL="SELECT sku||','||qty FROM inventory WHERE run_id=$RUN_ID ORDER BY sku;"
BEFORE="$(q "$ROWS_SQL")"
COUNT_BEFORE="$(printf '%s\n' "$BEFORE" | wc -l | tr -d ' ')"
TOTAL_BEFORE="$(q 'SELECT count(*) FROM inventory;')"
[ "$COUNT_BEFORE" = "3" ] || fail "expected 3 rows for this run before delete, found $COUNT_BEFORE"
log "rows for this run before delete: $COUNT_BEFORE (table total: $TOTAL_BEFORE)"
printf '%s\n' "$BEFORE" | tee -a "$OUT"
UID1="$(uid)"; PVC1="$(pvc)"
[ -n "$PVC1" ] || fail "could not determine the PVC used by $POD"
log "pod UID before: $UID1"
log "PVC before: $PVC1 -> $(kubectl -n "$NS" get pvc "$PVC1" -o jsonpath='{.spec.volumeName}')"

log "STEP 2: delete the pod"
T0="$(date +%s)"
kubectl -n "$NS" delete pod "$POD" --wait=true >/dev/null
log "pod deleted; waiting for StatefulSet to recreate it"
UID2=""
while [ $(( $(date +%s) - T0 )) -lt "$TIMEOUT" ]; do
  UID2="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  [ -n "$UID2" ] && break
  sleep 1
done
[ -n "$UID2" ] || fail "StatefulSet did not recreate $POD within ${TIMEOUT}s"
[ "$UID1" != "$UID2" ] || fail "pod UID did not change; $POD was not replaced"
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout="${TIMEOUT}s" >/dev/null || fail "replacement pod did not become Ready"
log "pod Ready again after $(( $(date +%s) - T0 ))s"
log "pod UID after:  $UID2 (confirmed: a NEW pod)"
PVC2="$(pvc)"
[ "$PVC1" = "$PVC2" ] || fail "PVC changed: $PVC1 -> $PVC2"
log "PVC after: $PVC2 (same)"

log "STEP 3: verify data"
AFTER=""
for _ in $(seq 1 15); do          # Postgres may still be finishing crash recovery
  if AFTER="$(q "$ROWS_SQL" 2>/dev/null)" && [ -n "$AFTER" ]; then break; fi
  sleep 2
done
TOTAL_AFTER="$(q 'SELECT count(*) FROM inventory;')"
log "rows for this run after delete: $(printf '%s\n' "$AFTER" | grep -c . || true) (table total: $TOTAL_AFTER)"
printf '%s\n' "$AFTER" | tee -a "$OUT"
[ "$BEFORE" = "$AFTER" ] || fail "rows after delete differ from rows before delete"
[ "$TOTAL_BEFORE" = "$TOTAL_AFTER" ] || fail "table total changed: $TOTAL_BEFORE -> $TOTAL_AFTER"

if [ "$CHECK_DNS" = "1" ]; then
  log "STEP 4: reachable through the stable Service DNS name from a separate pod"
  OK=0
  for _ in $(seq 1 10); do
    if kubectl -n "$NS" run "pgclient-$RUN_ID" --rm -i --restart=Never --labels=postgres-access=true \
         --image=postgres:16-alpine --command -- sh -c "sleep 10; pg_isready -h $SVC_HOST -p 5432 -d $DB -t 5" >/dev/null 2>&1; then OK=1; break; fi
    sleep 3
  done
  [ "$OK" = "1" ] || fail "database not reachable via $SVC_HOST after recreation"
  log "pg_isready OK via $SVC_HOST"
fi

if [ "$KEEP_ROWS" != "1" ]; then
  q "DELETE FROM inventory WHERE run_id=$RUN_ID;" >/dev/null
  log "removed this run's rows (KEEP_ROWS=1 to keep them)"
fi

trap - ERR
log "RESULT: PASS - new pod UID, same PVC, identical rows, Service reachable"
