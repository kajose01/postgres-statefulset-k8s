#!/usr/bin/env bash
# Pod-deletion data test: write rows, delete the pod, confirm the rows survive.
set -uo pipefail
NS=postgres; POD=postgres-0
OUT="$(dirname "$0")/../evidence/data-test.log"; : > "$OUT"
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$OUT"; }
q()   { kubectl -n $NS exec $POD -- psql -U postgres -d appdb -tA -c "$1"; }
uid() { kubectl -n $NS get pod $POD -o jsonpath='{.metadata.uid}'; }

log "STEP 1: create table and insert rows"
q "CREATE TABLE IF NOT EXISTS inventory (id serial PRIMARY KEY, sku text, qty int);" >/dev/null
q "INSERT INTO inventory (sku, qty) VALUES ('LAP-001',42),('MOU-002',310),('KEY-003',128);" >/dev/null
log "rows before delete: $(q 'SELECT count(*) FROM inventory;')"
q "SELECT id, sku, qty FROM inventory ORDER BY id;" | tee -a "$OUT"
UID1=$(uid); log "pod UID before: $UID1"
log "PVC/PV: $(kubectl -n $NS get pvc pgdata-postgres-0 -o jsonpath='{.metadata.name} -> {.spec.volumeName}')"

log "STEP 2: delete the pod"
T0=$(date +%s)
kubectl -n $NS delete pod $POD --wait=true >/dev/null
log "pod deleted; waiting for StatefulSet to recreate it"
until kubectl -n $NS get pod $POD >/dev/null 2>&1; do sleep 1; done
kubectl -n $NS wait --for=condition=Ready pod/$POD --timeout=180s >/dev/null
log "pod Ready again after $(( $(date +%s) - T0 ))s"
UID2=$(uid); log "pod UID after:  $UID2"
[ "$UID1" != "$UID2" ] && log "confirmed: a NEW pod (different UID)" || log "WARNING: same UID"

log "STEP 3: verify data"
log "rows after delete: $(q 'SELECT count(*) FROM inventory;')"
q "SELECT id, sku, qty FROM inventory ORDER BY id;" | tee -a "$OUT"
[ "$(q 'SELECT count(*) FROM inventory;')" = "3" ] && log "RESULT: PASS, data persisted" || log "RESULT: FAIL"
