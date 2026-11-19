#!/usr/bin/env bash
set -Eeuo pipefail
NS="${NS:-postgres}"; POD="${POD:-postgres-0}"; DB="${DB:-appdb}"; DBUSER="${DBUSER:-postgres}"
FILE="${1:?usage: restore.sh <backup.sql>}"
[ -f "$FILE" ] || { echo "No such file: $FILE"; exit 1; }
read -r -p "This OVERWRITES objects in '${DB}'. Type the database name to continue: " ans
[ "$ans" = "$DB" ] || { echo "Aborted."; exit 1; }
kubectl -n "$NS" exec -i "$POD" -- psql -U "$DBUSER" -d "$DB" -v ON_ERROR_STOP=1 < "$FILE"
echo "Restore complete."
