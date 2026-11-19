#!/usr/bin/env bash
# Network test through the stable DNS name, from separate client pods in namespace postgres.
#  1. labelled client (postgres-access=true): connects and runs a query (password from the Secret)   -> works
#  2. unlabelled client: the name RESOLVES, but TCP to 5432 gets no answer                           -> blocked by the NetworkPolicy
#  3. postgres-0 is deleted; a labelled client connects again through the same name                  -> works
# Evidence: evidence/network-test.log     Exit code 0 = PASS
set -Eeuo pipefail
NS=postgres
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/evidence/network-test.log"; mkdir -p "$ROOT/evidence"; : > "$OUT"
log()  { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$OUT"; }
fail() { log "RESULT: FAIL - $*"; exit 1; }
kubectl -n "$NS" get networkpolicy >/dev/null 2>&1 || fail "no NetworkPolicy found in namespace $NS"

apply_pod() { kubectl -n "$NS" delete pod "$1" --ignore-not-found --wait=true >/dev/null; kubectl -n "$NS" apply -f - >/dev/null; }
wait_done() { local p=""; for _ in $(seq 1 90); do p=$(kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.phase}'); case "$p" in Succeeded|Failed) echo "$p"; return;; esac; sleep 2; done; echo "Timeout"; }

allowed_pod() { apply_pod nt-allowed <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: nt-allowed, labels: {app: nt-client, postgres-access: "true"}}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: postgres:16-alpine
    env: [{name: PGPASSWORD, valueFrom: {secretKeyRef: {name: postgres-secret, key: POSTGRES_PASSWORD}}}]
    command: ["sh", "-c"]
    args: ["i=1; until pg_isready -h postgres-0.postgres.postgres.svc.cluster.local -U postgres -t 3; do i=$((i+1)); [ $i -gt 30 ] && exit 1; sleep 2; done; echo attempts=$i; psql -h postgres-0.postgres.postgres.svc.cluster.local -U postgres -d appdb -tAc 'SELECT current_user, count(*) FROM inventory'"]
YAML
}

log "TEST 1: labelled client -> postgres-0.postgres.postgres.svc.cluster.local:5432"
allowed_pod; P=$(wait_done nt-allowed)
log "client output: $(kubectl -n "$NS" logs nt-allowed | tr '\n' ' ')"
[ "$P" = "Succeeded" ] || fail "labelled client could not connect and query (phase $P)"
log "TEST 1 OK: connection and authenticated query worked (attempts = tries until the policy allowed the new pod)"

log "TEST 2: unlabelled client: DNS must resolve, TCP must get no answer"
apply_pod nt-blocked <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: nt-blocked, labels: {app: nt-client}}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: postgres:16-alpine
    command: ["sh", "-c"]
    args: ["getent hosts postgres-0.postgres.postgres.svc.cluster.local; pg_isready -h postgres-0.postgres.postgres.svc.cluster.local -U postgres -t 5"]
YAML
P=$(wait_done nt-blocked)
LOGS=$(kubectl -n "$NS" logs nt-blocked | tr '\n' ' ')
log "client output: $LOGS"
echo "$LOGS" | grep -q "postgres-0.postgres" || fail "unlabelled client could not even resolve the name; the test proves nothing"
[ "$P" = "Failed" ] || fail "unlabelled client was NOT blocked (phase $P)"
log "TEST 2 OK: name resolved, connection got no answer, so the NetworkPolicy blocks unlabelled pods"

log "TEST 3: delete postgres-0, then connect again through the same name"
kubectl -n "$NS" delete pod postgres-0 --wait=true >/dev/null
until kubectl -n "$NS" get pod postgres-0 >/dev/null 2>&1; do sleep 1; done
kubectl -n "$NS" wait --for=condition=Ready pod/postgres-0 --timeout=180s >/dev/null
allowed_pod; P=$(wait_done nt-allowed)
log "client output: $(kubectl -n "$NS" logs nt-allowed | tr '\n' ' ')"
[ "$P" = "Succeeded" ] || fail "not reachable through the stable name after recreation (phase $P)"
kubectl -n "$NS" delete pod nt-allowed nt-blocked --ignore-not-found >/dev/null
log "RESULT: PASS - reachable by stable DNS name before and after recreation; unlabelled pods are blocked"
