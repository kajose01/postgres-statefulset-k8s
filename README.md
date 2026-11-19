# PostgreSQL StatefulSet on Kubernetes

A single-instance PostgreSQL 16 database deployed as a StatefulSet. A StorageClass, PersistentVolume and PersistentVolumeClaim keep its data across pod deletion, and a script proves it.

## 1. Problem Statement

XYZ Corporation needs a database on Kubernetes that keeps its data when its pod is deleted or rescheduled. The task is to:

- deploy PostgreSQL as a StatefulSet with stable identity,
- back it with a StorageClass, a PV and a PVC,
- write data, delete the pod, and show the data is still there.

## 2. Scope and Limitations

- **Single instance (`replicas: 1`).** A StatefulSet provides a stable pod name (`postgres-0`), stable DNS and stable storage. It does **not** provide replication, failover or high availability. For HA, evaluate a PostgreSQL operator (e.g. CloudNativePG) or Patroni.
- **Node-local storage.** `rancher.io/local-path` keeps data on the node's filesystem (on k3s under `/var/lib/rancher/k3s/storage/<pv-name>` on the node). `Retain` keeps the PV when the PVC is deleted, but it does **not** protect against loss of the node or disk. Take regular backups (section 7), or use storage with node-failure protection for production.
- This is a demonstration of pod-level persistence, not a disaster-recovery design.

## 3. Repository Layout

    k8s/        namespace, storageclass, headless service, statefulset, secret template,
                networkpolicy.yaml, rbac.yaml
    scripts/    data-test.sh (pod-deletion data test), backup.sh, restore.sh, rotate-password.sh
    evidence/   data-test.log, run1-3.log, final-state.txt, networkpolicy-test.txt
    README.md

## 4. Steps to Build and Run

Prerequisites: a Kubernetes cluster with the `rancher.io/local-path` provisioner (k3s includes it) and `kubectl`.

    # 1. Namespace and StorageClass
    kubectl apply -f k8s/namespace.yaml -f k8s/storageclass.yaml

    # 2. Secret (generated at deploy time; piped via stdin so it is never printed,
    #    never in shell history and never on a command line)
    openssl rand -base64 18 | tr -d '\n' | kubectl -n postgres create secret generic postgres-secret \
      --from-file=POSTGRES_PASSWORD=/dev/stdin

    # 3. Headless Service, StatefulSet, access controls
    kubectl apply -f k8s/service.yaml -f k8s/statefulset.yaml
    kubectl apply -f k8s/rbac.yaml -f k8s/networkpolicy.yaml
    kubectl -n postgres rollout status sts/postgres

    # 4. Verify storage
    kubectl get storageclass
    kubectl -n postgres get sts,pods,pvc
    kubectl get pv

    # 5. Pod-deletion data test
    ./scripts/data-test.sh
    cat evidence/data-test.log

`k8s/secret.example.yaml` is a template only. The real Secret exists only in the cluster.

## 5. Connecting an Application

- Same namespace: `postgres-0.postgres:5432`
- Other namespace: `postgres-0.postgres.postgres.svc.cluster.local:5432`
- Connection string: `postgresql://postgres:<password>@postgres-0.postgres.postgres.svc.cluster.local:5432/appdb`
- The Service is headless and **internal only** (no NodePort or LoadBalancer). `k8s/networkpolicy.yaml` allows only pods labelled `postgres-access=true` to reach port 5432 (enforced only if the cluster's network plugin supports NetworkPolicy).
- A stable DNS name does not guarantee the database is accepting connections; the test checks both.

## 6. Data Persistence Test

`scripts/data-test.sh` tags 3 rows with a unique run id, records the pod UID and PVC, deletes `postgres-0`, waits for the StatefulSet to recreate it, then verifies the data. It **fails** (exit code 1, `RESULT: FAIL - <reason>` in the log) if:

- any `kubectl` or `psql` command fails,
- the replacement pod has the same UID (it was not replaced),
- the pod is not recreated or not Ready within 180 s,
- the pod's PVC changed,
- the rows after deletion differ from the rows before (compared row by row, not only by count),
- the table total changed,
- the database is not reachable through its Service DNS name from a separate pod afterwards.

It is safe to re-run: every run uses its own run id and removes only its own rows (`KEEP_ROWS=1` keeps them, `CHECK_DNS=0` skips the DNS check). Full output is written to `evidence/data-test.log`.

Latest run (from `evidence/run3.log`; runs 1 to 3 all passed, see `evidence/run1.log` to `run3.log`):

| Check | Before delete | After delete |
|---|---|---|
| Rows for the run | 3 | 3 |
| Pod UID | `745c9c59-53af-4680-8a0c-4e61e1fc3887` | `c41ade02-2def-4f9c-9760-2953e9c7a926` (different) |
| PVC | pgdata-postgres-0 | pgdata-postgres-0 (same) |
| Ready after | | 7 s |
| Result | | **PASS** |

Storage objects (from `evidence/final-state.txt`): PVC `pgdata-postgres-0` is Bound to a 1Gi PV (`ReadWriteOnce`, StorageClass `pg-local-path`, reclaim policy `Retain`).

## 7. Backup and Restore

    ./scripts/backup.sh                         # writes backups/appdb-<timestamp>.sql
    ./scripts/restore.sh backups/<file>.sql     # asks you to type the database name first

Backups contain real data: `backups/` is in `.gitignore`.

## 8. Credentials and Secrets

- The password is generated at deploy time and goes straight into a Kubernetes Secret. Only `secret.example.yaml` is committed; `secret.yaml` is in `.gitignore`. Never put real credentials in Git or in evidence files.
- **Access:** `k8s/rbac.yaml` lets only the `postgres-admin` ServiceAccount `get` `postgres-secret`. Review who else has `get`/`list` on Secrets in the namespace.
- **Rotation:** `./scripts/rotate-password.sh` changes the password in PostgreSQL, updates the Secret and restarts the StatefulSet. Restart applications that use the Secret afterwards.
- **Encryption at rest:** Secrets are only base64-encoded by default. Enable etcd encryption (or a KMS provider) on the cluster; for production use an external secrets manager.
- Note: the `postgres` image trusts local socket connections inside the pod, so the password protects network (TCP) connections.

## 9. Optimization Techniques Used

- **volumeClaimTemplates:** each StatefulSet pod gets its own PVC, so scaling out later does not share one disk.
- **Custom StorageClass `pg-local-path`:** `reclaimPolicy: Retain` keeps the data even if the PVC is deleted, and `WaitForFirstConsumer` binds the volume on the node where the pod is scheduled.
- **Headless Service:** gives the pod a stable DNS name (`postgres-0.postgres`).
- **Secret for credentials:** see section 8.
- **PGDATA in a subdirectory:** avoids the "directory not empty" error that appears when Postgres initializes directly on a fresh volume mount root.
- **Small image:** `postgres:16-alpine`.
- **Resource requests and limits:** CPU 100m / 500m and memory 256Mi / 512Mi. These are starting values: a container that exceeds its memory limit is OOM-killed and restarted, and one that exceeds its CPU limit is throttled. Validate with a representative load (e.g. `pgbench`) before production use.
- **Probes:** `pg_isready` for readiness and liveness, plus a startup probe (up to 300 s) so slow first-time initialisation is not killed by the liveness probe. `pg_isready` checks that PostgreSQL accepts connections, not that every query works; the data test covers queries.

## 10. Challenges Faced and Solutions

| Challenge | Solution |
|---|---|
| Keeping the database password out of Git and logs | Generated at deploy time into a Secret via stdin, committed only `secret.example.yaml`, and added `secret.yaml` to `.gitignore`. |
| Postgres can fail to initialize on a fresh volume root | Set `PGDATA` to a subdirectory of the mount. |
| Proving the pod really was replaced | The test fails unless the pod UID changes, and also checks the PVC is unchanged. |
| A test that could report PASS after a failed command | `set -Eeuo pipefail`, explicit `fail` checks, row-by-row comparison. |
| Reruns accumulated rows and broke the count check | Rows are tagged with a unique run id and removed after the run. |
| `Retain` leaves the PV behind after cleanup | Documented in section 11. |
| Pod crash-looped for hours: crash recovery failed with `could not signal for checkpoint: Permission denied` and the entrypoint `gosu` step hung | Backed up the data, then diagnosed with a probe-free debug pod on the same PVC. The container now runs as uid 70 with AppArmor `Unconfined` for this pod, plus a startup probe. The data survived intact. |
| Test client got `no response` right after starting | The NetworkPolicy takes a few seconds to recognise a new pod's label, so the test client waits 10 s before connecting (see `evidence/networkpolicy-test.txt`). |

## 11. Cleanup: What Each Command Deletes

| Command | Effect on data |
|---|---|
| `kubectl delete pod postgres-0` | None. Pod is recreated and reuses the PVC. |
| `kubectl delete statefulset postgres` | None. The PVC is kept. |
| `kubectl delete pvc pgdata-postgres-0` | PV becomes `Released` (Retain). Data is still on the node's disk. |
| `kubectl delete pv <pv-name>` | Removes the PV object. With local-path the files may remain on the node; remove that directory manually to destroy the data. |
| `kubectl delete namespace postgres` | Deletes the PVC and all namespaced objects. The PV is retained. |
| `kubectl delete storageclass pg-local-path` | Does not touch existing PVs or data. |

**Run `./scripts/backup.sh` before deleting a PV that holds important data.**

Full removal:

    kubectl delete namespace postgres
    kubectl get pv                      # find the Released PV
    kubectl delete pv <pv-name>
    kubectl delete storageclass pg-local-path
    kubectl get pv,pvc -A               # verify nothing is left

**Recovering a retained PV** after its PVC was deleted: clear its claim reference with
`kubectl patch pv <pv-name> -p '{"spec":{"claimRef":null}}'`, then create a PVC named `pgdata-postgres-0` in the `postgres` namespace with the same StorageClass and size and let the StatefulSet bind to it.

## Access to the database Secret (RBAC)

`k8s/rbac.yaml` creates the ServiceAccount `postgres-admin` and a Role that allows only `get` on the single Secret `postgres-secret`. Any other ServiceAccount in the namespace, including `default`, cannot read it. The check and its output are in `evidence/rbac-check.txt`:

    kubectl auth can-i get secret/postgres-secret -n postgres --as=system:serviceaccount:postgres:postgres-admin   # yes
    kubectl auth can-i get secret/postgres-secret -n postgres --as=system:serviceaccount:postgres:default          # no
    kubectl auth can-i list secrets -n postgres --as=system:serviceaccount:postgres:postgres-admin                 # no

The Secret is base64 encoded, not encrypted, unless the cluster enables encryption at rest. On k3s, `sudo k3s secrets-encrypt status` shows whether it is on. This project does not turn it on, and a production cluster should. Rotate the password with `./scripts/rotate-password.sh`, then run the data test again to confirm access still works. Keep passwords out of shared terminals and logs.

## Probes and resource limits

| Probe | Check | Purpose |
|---|---|---|
| `startupProbe` | `pg_isready`, every 5 s, up to 60 failures (300 s) | Gives first-time initialisation time before the other probes begin to count |
| `readinessProbe` | `psql -c 'SELECT 1'`, every 5 s, timeout 3 s | Traffic only reaches a database that can execute SQL, not just one that accepts connections |
| `livenessProbe` | `pg_isready`, every 10 s | A cheap check, so a busy database is not restarted by mistake |

Resources: requests 100m CPU / 256Mi memory, limits 500m CPU / 512Mi memory.

- At the **CPU limit** the container is throttled: queries get slower, but nothing restarts.
- At the **memory limit** the kernel kills the container (reason `OOMKilled`). Kubernetes restarts it, PostgreSQL replays its write-ahead log, and the data on the PVC is intact. Raise the memory limit if you see this under a real workload.

### Load test result

`scripts/load-test.sh` runs `pgbench` in a separate database (`benchdb`, so `appdb` is untouched) with 8 clients for 30 seconds. The log is `evidence/load-test.log`. In the recorded run the database processed 29,481 transactions with 0 failures (about 980 transactions per second, 8.1 ms average latency), the pod did not restart, it was not `OOMKilled`, and all 300,000 benchmark rows were written. This shows the pod stays healthy within its 500m CPU and 512Mi memory limits at this load. It does not show where those limits break. To find out, run `CLIENTS=40 SCALE=10 ./scripts/load-test.sh` and watch for restarts or an `OOMKilled` reason.
