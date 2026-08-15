# Loki Backup — MinIO / S3 (CronJob)

Automated backup of a **Loki (Monolithic)** instance's on-disk data to an **S3-compatible bucket (MinIO)**. A `CronJob` runs the `aws-cli` container daily at **02:00**, syncs Loki's `chunks`, `index` and `wal` directories (from the Loki PVC) into `s3://<bucket>/<dir>/`, and keeps 3 job histories.

> The PVC claim name `storage-logging-0` and mount path `/var/loki` in these manifests match a Loki StatefulSet released as `logging` with a `storage-...` volumeClaimTemplate (see `Standalone-charts/Loki`).

## Table of Contents

1. [Files](#1-files)
2. [How the Backup Works](#2-how-the-backup-works)
3. [Prerequisites](#3-prerequisites)
4. [Deploy](#4-deploy)
5. [Run Once Manually](#5-run-once-manually)
6. [Verify](#6-verify)
7. [Restore](#7-restore)
8. [Tune / Customize](#8-tune--customize)
9. [Troubleshooting](#9-troubleshooting)

## 1. Files

| File               | Kind                 | What it does                                                                 |
|--------------------|----------------------|------------------------------------------------------------------------------|
| `secret.yaml`      | `Secret`             | MinIO/S3 credentials + endpoint + bucket name (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `MINIO_ENDPOINT_URL`, `S3_BUCKET`) |
| `configmap.yaml`   | `ConfigMap`          | Holds `backup.sh` — the backup logic (sync `chunks`/`index`/`wal` → S3)       |
| `cron.yaml`        | `CronJob`            | Schedules the backup every day at `02:00` (`0 2 * * *`), `Forbid` concurrency |
| `single-job.yaml`  | `Job`                | One-off copy of the backup pod — run it manually to test or trigger a backup  |

**Relationship:** the `CronJob`/`Job` inject the `backup.sh` script (ConfigMap) and the MinIO credentials (Secret) into the `amazon/aws-cli` container, and mount the Loki PVC at `/var/loki`.

## 2. How the Backup Works

```
CronJob (daily 02:00) / Job (manual)
        │
        ▼
  amazon/aws-cli:2.17.38  (/bin/sh /scripts/backup.sh)
        │
        ├─ mounts Loki PVC "storage-logging-0" at /var/loki   (chunks/, index/, wal/)
        ├─ env from Secret "minio-backup-secret"
        │
        ▼
  for PATH_NAME in chunks index wal:
      [ -d && non-empty ] ──► aws s3 sync  /var/loki/<PATH_NAME>  s3://<bucket>/<PATH_NAME>/
                                            └─ --endpoint-url = MINIO_ENDPOINT_URL (MinIO, path-style)
```

- **`aws s3 sync`** — copies only changed/new files (delta, not full re-copy).
- Empty or missing directories are **skipped**; if *all* three are skipped the script prints a warning and exits `0` (no-op).
- `set -e` — the Job fails (backoff + retry, max 2) if any sync errors.

### Backup layout in the bucket

```
s3://loki-backup/
├── chunks/…      # log chunks
├── index/…       # index shards
└── wal/…         # write-ahead log (for replay)
```

## 3. Prerequisites

- Loki (Monolithic) deployed in namespace `logging` with PVC `storage-logging-0` (matches `Standalone-charts/Loki`).
- MinIO/S3 endpoint reachable from the cluster.
- The `loki-backup` bucket already exists in MinIO (the script does **not** create it).

## 4. Deploy

```bash
# 1. namespace must already exist (Loki is running there)
kubectl create ns logging        # if not present

# 2. Secret + ConfigMap (edit credentials/endpoint/bucket first!)
kubectl apply -f secret.yaml
kubectl apply -f configmap.yaml

# 3. CronJob
kubectl apply -f cron.yaml
```

```bash
# check the schedule and job history
kubectl get cronjob -n logging
kubectl get jobs -n logging
```

## 5. Run Once Manually

To trigger a backup **right now** (test or one-off) use `single-job.yaml`:

```bash
kubectl apply -f single-job.yaml
kubectl get job -n logging
kubectl logs job/loki-backup-test -n logging --follow
```

> Only one of `cron.yaml` + `single-job.yaml` should run at a time — the CronJob has `concurrencyPolicy: Forbid`, but a manual Job doesn't know about the CronJob's pods.

## 6. Verify

```bash
# job output — expect "Backup Completed Successfully at <ts>"
kubectl logs job/loki-backup-test -n logging

# objects in the bucket (from any aws-cli pod)
kubectl exec -n logging <backup-pod> -- \
  aws s3 ls s3://loki-backup/chunks/ --endpoint-url=http://host.minikube.internal:9000

# cron history (3 successes / 3 failures kept)
kubectl get cronjob loki-backup -n logging -o jsonpath='{.status}' | python3 -m json.tool
```

## 7. Restore

Sync is bidirectional-safe, so restore is a reverse `aws s3 sync` into the PVC. Only do this when Loki is **stopped** (scale the StatefulSet to 0) to avoid WAL/index corruption:

```bash
kubectl scale sts logging -n logging --replicas=0

# copy back from the bucket into the PVC (adjust paths/endpoint)
aws s3 sync s3://loki-backup/chunks/  /var/loki/chunks/  --endpoint-url=$MINIO_ENDPOINT_URL
aws s3 sync s3://loki-backup/index/   /var/loki/index/   --endpoint-url=$MINIO_ENDPOINT_URL
aws s3 sync s3://loki-backup/wal/     /var/loki/wal/     --endpoint-url=$MINIO_ENDPOINT_URL

kubectl scale sts logging -n logging --replicas=1
```

## 8. Tune / Customize

| What                  | Where                          | Example                          |
|-----------------------|--------------------------------|----------------------------------|
| Schedule              | `cron.yaml` → `spec.schedule`  | `0 2 * * *` = daily 02:00        |
| Keep more history     | `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` | `5` / `5`        |
| Bucket name           | `secret.yaml` → `S3_BUCKET`    | `loki-backup`                    |
| Endpoint              | `secret.yaml` → `MINIO_ENDPOINT_URL` | `http://host.minikube.internal:9000` |
| CPU / memory          | container `resources`          | bump limits for big PVCs         |
| Extra retention (e.g. Prune old backups) | add a step in `backup.sh` | `aws s3 rm s3://bucket/chunks/ --recursive --older-than 7d` |
| CronJob timezone      | `spec.schedule` (cron with TZ) or `spec.timeZone` (K8s ≥1.27) | `"0 2 * * *"` + `timeZone: "Asia/Kolkata"` |

> `secret.yaml` holds the MinIO dev credentials (`minioadmin`/`minioadmin`) and the minikube host endpoint (`host.minikube.internal`). For any real cluster, override these with the actual MinIO user / password / in-cluster endpoint (e.g. `http://minio.ldc.opstree.dev:9000`).

## 9. Troubleshooting

| Symptom | Check |
|---------|-------|
| Job keeps failing (backoff) | `kubectl describe job/loki-backup-test -n logging`; `kubectl logs` — usually endpoint DNS or auth |
| `Could not connect to the endpoint URL` | `MINIO_ENDPOINT_URL` reachable from the pod; on minikube `host.minikube.internal` is the host MinIO |
| `Access Denied` / 403 | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` wrong, or bucket permissions |
| `NoSuchBucket` | create the bucket in MinIO first (the script does not create it) |
| `WARNING: Nothing to back up` | all of `chunks`/`index`/`wal` missing/empty — PVC name may not match (`kubectl get pvc -n logging`) |
| Stale PVC / wrong data backed up | PVC claim `storage-logging-0` hard-coded — change it if the Loki StatefulSet name differs |
| CronJob never runs | check `schedule` and that the cluster has a running `kube-scheduler`; timezone uses the scheduler's TZ by default |
