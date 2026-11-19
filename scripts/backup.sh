#!/usr/bin/env bash
set -Eeuo pipefail
NS="${NS:-postgres}"; POD="${POD:-postgres-0}"; DB="${DB:-appdb}"; DBUSER="${DBUSER:-postgres}"
OUT="${1:-backups/${DB}-$(date +%Y%m%d-%H%M%S).sql}"
mkdir -p "$(dirname "$OUT")"
kubectl -n "$NS" exec "$POD" -- pg_dump -U "$DBUSER" -d "$DB" --clean --if-exists > "$OUT"
[ -s "$OUT" ] || { echo "Backup is empty"; rm -f "$OUT"; exit 1; }
echo "Backup written to $OUT"
