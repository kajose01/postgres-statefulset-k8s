# PostgreSQL StatefulSet on Kubernetes

A single-instance PostgreSQL 16 database deployed as a StatefulSet. A StorageClass, PersistentVolume and PersistentVolumeClaim keep its data across pod deletion, and a script proves it.

## 1. Problem Statement

XYZ Corporation needs a database on Kubernetes that keeps its data when its pod is deleted or rescheduled. The task is to:

- deploy PostgreSQL as a StatefulSet with stable identity,
- back it with a StorageClass, a PV and a PVC,
- write data, delete the pod, and show the data is still there.

## 2. Repository Layout

    k8s/        namespace, storageclass, headless service, statefulset, secret template
    scripts/    data-test.sh (pod-deletion data test)
    evidence/   data-test.log, final-state.txt
    README.md

## 3. Steps to Build and Run

Prerequisites: a Kubernetes cluster with the `rancher.io/local-path` provisioner (k3s includes it) and `kubectl`.

    # 1. Namespace and StorageClass
    kubectl apply -f k8s/namespace.yaml -f k8s/storageclass.yaml

    # 2. Secret (password generated at deploy time, never committed)
    kubectl -n postgres create secret generic postgres-secret \
      --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 18)"

    # 3. Headless Service and StatefulSet
    kubectl apply -f k8s/service.yaml -f k8s/statefulset.yaml
    kubectl -n postgres rollout status sts/postgres

    # 4. Verify storage
    kubectl get storageclass
    kubectl -n postgres get sts,pods,pvc
    kubectl get pv

    # 5. Pod-deletion data test
    ./scripts/data-test.sh
    cat evidence/data-test.log

`k8s/secret.example.yaml` is a template only. The real Secret exists only in the cluster.

## 4. Data Persistence Test

`scripts/data-test.sh` creates a table, inserts 3 rows, records the pod UID, deletes `postgres-0`, waits for the StatefulSet to recreate it, then counts the rows again. Full output is in `evidence/data-test.log`.

| Check | Before delete | After delete |
|---|---|---|
| Rows in `inventory` | 3 | 3 |
| Pod UID | 8e47b496-dd72-427c-809b-81c12499e4a3 | 0ea0d56e-cd45-45aa-99fb-f60295a3d820 |
| PVC | pgdata-postgres-0 | pgdata-postgres-0 (same) |

The pod was recreated and Ready again after 7 seconds. The new UID proves it is a different pod, and the identical rows prove the data lives on the volume, not in the pod. Result: **PASS**.

Storage objects (from `evidence/final-state.txt`): PVC `pgdata-postgres-0` is Bound to a 1Gi PV (`ReadWriteOnce`, StorageClass `pg-local-path`, reclaim policy `Retain`).

## 5. Optimization Techniques Used

- **volumeClaimTemplates:** each StatefulSet pod gets its own PVC, so scaling out later does not share one disk.
- **Custom StorageClass `pg-local-path`:** `reclaimPolicy: Retain` keeps the data even if the PVC is deleted, and `WaitForFirstConsumer` binds the volume on the node where the pod is scheduled.
- **Headless Service:** gives the pod a stable DNS name (`postgres-0.postgres`).
- **Secret for credentials:** the password is generated with `openssl` and goes straight into a Kubernetes Secret, so it never appears in Git or logs.
- **PGDATA in a subdirectory:** avoids the "directory not empty" error that appears when Postgres initializes directly on a fresh volume mount root.
- **Small image:** `postgres:16-alpine`.
- **Resource requests and limits:** CPU 100m / 500m and memory 256Mi / 512Mi.
- **Probes:** `pg_isready` for both readiness and liveness, so traffic only reaches a database that accepts connections.

## 6. Challenges Faced and Solutions

| Challenge | Solution |
|---|---|
| Keeping the database password out of Git | Generated it at deploy time into a Secret, committed only `secret.example.yaml`, and added `secret.yaml` to `.gitignore`. |
| Postgres can fail to initialize on a fresh volume root | Set `PGDATA` to a subdirectory of the mount. |
| Proving the pod really was replaced | The test compares pod UIDs before and after the delete. |
| `Retain` leaves the PV behind after cleanup | Documented below. |

## 7. Cleanup

    kubectl delete namespace postgres
    kubectl delete pv <pv-name>        # needed because of reclaimPolicy: Retain
    kubectl delete storageclass pg-local-path

Re-running `data-test.sh` on a populated table inserts 3 more rows and the check will report FAIL. Delete the table or the namespace first for a clean run.
