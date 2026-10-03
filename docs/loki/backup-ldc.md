# Loki + Fluent-bit Config Comparison

**Older / Previous deployment:** Document 2
**Current (deployed in cluster):** Document 1

---

## 1. Storage Backend (`loki.storage` / `commonStorageConfig`)

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| `loki.image` | not set (chart default) | `quay.io/opstree/loki:3.6-debian13` | Pinned to a specific Loki image/tag for reproducible, controlled upgrades. |
| `storage.type` | not set | `s3` | Explicitly moved storage backend from filesystem/bundled-minio default to S3-compatible object storage. |
| `commonStorageConfig.s3` | not present | Added `endpoint`, `bucketnames`, `access_key_id`, `secret_access_key`, `s3forcepathstyle: true`, `insecure: false` | Points Loki to an external/standalone MinIO instance instead of the in-cluster MinIO subchart, enabling durable, external object storage. |
| `minio.enabled` | `true` (bundled MinIO subchart) | `false` | Bundled MinIO no longer deployed since an external MinIO endpoint is now used directly. |

## 2. Compactor / Retention (`loki.compactor`)

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| `delete_request_store` | `filesystem` | `s3` | Must match the new object-store backend so delete requests are tracked in S3 instead of local filesystem. |
| `retention_delete_delay` | `2h` | `1h` | Faster reclaiming of storage space after retention deletion is triggered. |
| `retention_delete_worker_count` | not set | `10` | Added explicit worker parallelism to speed up compaction/delete processing under higher log volume. |

## 3. Ingester Runtime Config (`loki.ingester`)

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| `wal.enabled`, `wal.dir`, `flush_on_shutdown` | not set | `enabled: true`, `/var/loki/wal`, `flush_on_shutdown: true` | Added write-ahead log for crash/restart durability, preventing in-memory log loss. |
| `chunk_idle_period` | not set | `20m` | Explicitly controls how long an idle chunk stays open before flush, tuning memory usage. |
| `chunk_retain_period` | not set | `300s` | Keeps recently flushed chunks briefly in memory to serve fresh queries faster. |
| `max_chunk_age` | not set | `10m` | Caps chunk age to bound memory and ensure timely flush to storage. |
| `flush_check_period` | not set | `30s` | Sets how frequently the flush loop checks for chunks to flush. |
| `chunk_target_size` | not set | `1536000` | Targets a specific chunk size for more efficient storage/query performance. |

## 4. Limits Config (`loki.limits_config`)

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| `retention_period` | `7d` | `8h` | Retention drastically shortened, likely to control storage costs given higher ingestion volume from the new S3 backend. |
| `reject_old_samples`, `reject_old_samples_max_age` | not set | `true`, `6h` | Added to reject stale/late log samples beyond 6h, protecting ingestion pipeline integrity. |
| `ingestion_rate_mb` / `ingestion_burst_size_mb` | not set | `32` / `32` | Explicit ingestion throughput caps added to protect the cluster from ingestion spikes. |
| `per_stream_rate_limit` / `per_stream_rate_limit_burst` | not set | `10MB` / `20MB` | Added per-stream limits to prevent a single noisy stream from overwhelming ingesters. |
| `split_queries_by_interval` | not set | `15m` | Improves large query performance by splitting into parallel sub-queries. |
| `max_cache_freshness_per_query` | not set | `10m` | Ensures query result caching doesn't serve overly stale data. |
| `query_timeout` | not set | `300s` | Explicit timeout added to prevent runaway queries from hanging resources. |
| `volume_enabled` | not set | `true` | Enables log volume API/endpoint for observability into log volume by label. |

## 5. Query Path

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| `querier.max_concurrent` | `1` | `4` | Increased concurrency to improve query throughput (more CPU/memory now available/allocated). |
| `query_stats_enabled` | not set | `true` | Added to expose query statistics for monitoring/troubleshooting query performance. |
| `auth_enabled` | `false` | not set (removed) | Likely removed to fall back to chart default; multi-tenancy/auth stance may be managed elsewhere now. |

## 6. Server Tuning (`loki.structuredConfig`)

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| `server.http_server_read_timeout` / `write_timeout` | not set | `600s` / `600s` | Increased HTTP timeouts to support long-running queries/log pushes without premature disconnects. |

## 7. Ingester Persistence (top-level `ingester` component)

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| PVC size (`persistence.claims[0].size`) | `2Gi` | `20Gi` | Increased disk allocation to accommodate WAL + higher chunk retention needs and avoid disk pressure. |

## 8. Fluent-bit — Structure & Image

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| Chart values nesting | `fluent-bit:` (single level) | `fluent-bit: → fluent-bit:` (double-nested) | Reflects a fluent-bit chart/subchart version change requiring an extra nesting level in values. |
| `image` | not set (chart default) | `quay.io/opstree/fluent-bit:5.0.3` | Pinned to a specific fluent-bit image/tag for controlled, reproducible upgrades. |

## 9. Fluent-bit Input Section

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| `Buffer_Max_Size` | not set | `512k` | Added explicit buffer cap per monitored file to control memory usage per tailed file. |
| `Mem_Buf_Limit` | `5MB` | `20MB` | Increased buffer limit to handle higher log throughput without dropping logs. |
| `Ignore_Older` | `4h` | `2h` | Reduced window for ignoring old log files, aligning with shorter Loki retention and faster onboarding of new pods' logs. |

## 10. Fluent-bit Kubernetes Filter Section

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| `Keep_Log` | `On` | `Off` | Drops the raw `log` field after merging, reducing duplicate/redundant data sent to Loki. |
| `Buffer_Size` | not set | `5MB` | Added explicit buffer size for the Kubernetes metadata filter to handle metadata lookups reliably. |
| `Use_Kubelet` | not set | `Off` | Explicitly disabled kubelet-based metadata lookup, relying on API server instead (likely due to network/permission setup). |
| `Kubelet_Port` | not set | `10250` | Set for completeness even though `Use_Kubelet` is off, likely a safe-default addition. |
| `Labels` | not set | `On` | Enables inclusion of pod labels in log metadata for richer filtering in Loki. |
| `Annotations` | not set | `On` | Enables inclusion of pod annotations in log metadata for richer filtering in Loki. |

## 11. Fluent-bit Output Section

| Setting | Previous | Current | Reason for Change |
|---|---|---|---|
| `drop_single_key` | `on` | `Off` | Changed to preserve structured single-key records instead of flattening them, likely to retain more log structure in Loki. |
| `labels` — `rems_environment` | not present | Added | New label added to support filtering/querying logs by environment in Loki/Grafana. |
| `labels` — `cluster` | `ldc-gk` | `base-vcluster` | Cluster identifier updated to reflect the actual (new/renamed) cluster this fluent-bit is now running in. |
| `remove_keys` | `kubernetes` | `kubernetes` | Unchanged. |

---

### Summary
The current deployment moves Loki from an in-cluster/bundled MinIO + filesystem-oriented setup to an **external S3-compatible object store**, adds **WAL-based durability**, tightens **retention to 8h** while adding much stronger **ingestion/rate limiting**, increases **ingester storage (2Gi → 20Gi)**, and pins explicit **container image versions** for both Loki and fluent-bit. Fluent-bit itself gains richer Kubernetes metadata (labels/annotations), updated buffering, and a new `rems_environment` / `cluster=base-vcluster` labeling scheme, indicating this is a more mature, production-hardened configuration compared to the earlier setup.
