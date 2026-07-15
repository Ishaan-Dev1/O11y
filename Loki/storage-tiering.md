# Storage Tiering in Loki

## 1. Loki Does Not Support Storage Tiering Natively

Loki is a **single storage backend** system — at any given time it writes chunks and indices to **one** configured store (filesystem, S3, GCS, Azure Blob, etc.), not multiple. There is no built-in concept of "hot" vs "cold" tiers, no automatic movement of older data to cheaper/long-term storage, and no dual-write to two backends simultaneously. Whatever `storage.type` is set in the config is the only place data goes.

**Implication:** If we want tiering (e.g. recent logs on fast storage, older logs archived elsewhere), Loki itself will not do this — it has to be built externally.

## 2. Why Filesystem (PVC) Storage Doesn't Work in Distributed Mode

refrence: https://grafana.com/docs/loki/latest/operations/storage/filesystem/

Filesystem/PVC storage is only viable in **single-binary/monolithic** deployments. It is **not supported** in `Distributed` or `Simple Scalable` deployment modes. Reasons:

- **Decoupled components need shared access.** In distributed mode, Ingesters, Queriers, Compactor, and Index Gateway all run as separate, independently-scaled processes. Every one of them needs simultaneous read/write access to the *same* chunks and index data. A local PVC is mounted to one pod (or a fixed set via ReadWriteOnce) — it cannot be concurrently and consistently accessed by multiple independently scheduled components across nodes.
- **BoltDB file-locking conflict.** Loki's index store (`boltdb-shipper`) uses BoltDB, which is designed so that **only one active process can hold the file lock at a time**. In distributed mode, multiple ingesters/queriers would need to open the same index file concurrently — BoltDB's locking model does not allow this, causing lock contention/corruption risk.
- **No shared filesystem semantics.** Object storage (S3/GCS/MinIO) provides the concurrent, network-accessible read/write semantics a distributed architecture needs. A local disk (PVC) is inherently single-node-attached and can't provide that.

This is why our `values.yaml` uses `storage.type: s3` (MinIO) instead of a PVC for chunk/index storage, even though `deploymentMode: Distributed` is set.

## 3. Loki Cannot Move Data Between Storage Tiers by Itself

Loki has no internal job, process, or configuration option to **migrate or copy** data from its configured store to a different store (e.g. PVC → S3, or S3 → cheaper cold storage). Retention/compaction only deletes data past `retention_period` — it does not relocate it. Any tiering/archival has to be handled **outside** Loki, by an external process.

## 4. Our Solution — CronJob-Based Backup to MinIO

Since Loki won't tier data itself, we built a scheduled backup job that copies chunk data from the local PVC to MinIO (S3-compatible) object storage, using three manifests:

### a. CronJob (`loki-backup`)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: loki-backup
  namespace: logging
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  startingDeadlineSeconds: 300

  jobTemplate:
    spec:
      activeDeadlineSeconds: 3600
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure

          containers:
            - name: backup
              image: amazon/aws-cli:2.17.38
              imagePullPolicy: IfNotPresent

              command:
                - /bin/sh
                - /scripts/backup.sh

              envFrom:
                - secretRef:
                    name: minio-backup-secret

              resources:
                requests:
                  cpu: "100m"
                  memory: "128Mi"
                limits:
                  cpu: "500m"
                  memory: "512Mi"

              volumeMounts:
                - name: loki-storage
                  mountPath: /var/loki

                - name: backup-script
                  mountPath: /scripts

          volumes:
            - name: loki-storage
              persistentVolumeClaim:
                claimName: storage-logging-0

            - name: backup-script
              configMap:
                name: loki-backup-script
                defaultMode: 0755

```
- Runs daily at `02:00` (`schedule: "0 2 * * *"`).
- `concurrencyPolicy: Forbid` — prevents overlapping backup runs if one is still in progress.
- Mounts the same PVC (`storage-logging-0`) the ingester writes to, at `/var/loki`.
- Mounts a `ConfigMap` containing the backup script at `/scripts`.
- Uses `amazon/aws-cli` image to push data via `aws s3 sync`.
- `activeDeadlineSeconds`/`backoffLimit` guard against a stuck or endlessly-retrying job.

### b. ConfigMap (`loki-backup-script`)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-backup-script
  namespace: logging
data:
  backup.sh: |
    #!/bin/sh
    set -e

    DATE=$(date +%Y-%m-%d_%H-%M-%S)

    echo "================================="
    echo "Starting Loki Backup"
    echo "Timestamp : $DATE"
    echo "================================="

    # Verify source directory exists
    if [ ! -d "/var/loki/chunks" ]; then
      echo "ERROR: /var/loki/chunks directory not found. Aborting."
      exit 1
    fi

    # Verify source directory is not empty
    if [ -z "$(ls -A /var/loki/chunks)" ]; then
      echo "WARNING: /var/loki/chunks is empty. Nothing to backup."
      exit 0
    fi

    echo "Uploading Chunks..."

    aws s3 sync \
      /var/loki/chunks \
      s3://loki-backup/chunks/$DATE \
      --endpoint-url=${MINIO_ENDPOINT_URL}

    echo "Backup Completed Successfully at $DATE"

```
- Contains `backup.sh`, which:
  - Verifies `/var/loki/chunks` exists and isn't empty before proceeding (fails safe, doesn't error on empty state).
  - Runs `aws s3 sync /var/loki/chunks s3://loki-backup/chunks/$DATE --endpoint-url=${MINIO_ENDPOINT_URL}` — syncs chunks into a timestamped folder in the `loki-backup` bucket on MinIO.

### c. Secret (`minio-backup-secret`)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-backup-secret
  namespace: logging
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: minioadmin
  AWS_SECRET_ACCESS_KEY: #passowed
  MINIO_ENDPOINT_URL: https://minio.ldc.opstree.dev:9000
```
- Supplies `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `MINIO_ENDPOINT_URL` as env vars to the CronJob via `envFrom`, so the AWS CLI can authenticate against MinIO.

**Net effect:** This CronJob acts as Loki's missing "tiering" mechanism — periodically archiving chunk data from local PVC storage out to object storage, since Loki has no native way to do this on its own.


<img width="3360" height="1930" alt="image" src="https://github.com/user-attachments/assets/e7b7ffc2-987b-47ef-bd86-25cb9b99316b" />


