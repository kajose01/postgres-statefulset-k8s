#!/usr/bin/env bash
# Rotates the postgres password without printing it or putting it on a command line.
set -Eeuo pipefail
NS="${NS:-postgres}"; POD="${POD:-postgres-0}"
NEW="$(openssl rand -base64 18 | tr -d '\n')"
printf "ALTER USER postgres WITH PASSWORD '%s';\n" "$NEW" \
  | kubectl -n "$NS" exec -i "$POD" -- psql -U postgres -v ON_ERROR_STOP=1 >/dev/null
printf '%s' "$NEW" | kubectl -n "$NS" create secret generic postgres-secret \
  --from-file=POSTGRES_PASSWORD=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" rollout restart sts/postgres >/dev/null
echo "Password rotated. Restart any applications that use postgres-secret."
