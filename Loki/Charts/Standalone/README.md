# Loki (Monolithic) + Fluent Bit — Standalone Chart (v1.0.0)

Self-contained umbrella chart for **Grafana Loki in Monolithic (SingleBinary) mode** with **Fluent Bit** as the log collector. It wraps the upstream `grafana-community/loki` chart pinned at the **N-1 stable release** (`loki` **18.7.6** / appVersion **3.7.6**) plus the `ot-container-kit/fluent-bit` chart (**0.0.2**), and drives the subchart in Monolithic mode via `deploymentMode: Monolithic`.

The monolithic topology runs every Loki role (distributor, ingester, querier, compactor, ...) inside a **single StatefulSet replica** — the simplest deployable Loki. Suitable for small installs (up to a few tens of GB/day) without HA.

## Table of Contents

1. [Chart Structure](#1-chart-structure)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Deploy to a Cluster](#4-deploy-to-a-cluster)
5. [Deploy to Minikube](#5-deploy-to-minikube)
6. [Storage & Retention](#6-storage--retention)
7. [Log Pipeline — Fluent Bit](#7-log-pipeline--fluent-bit)
8. [Verification](#8-verification)
9. [Disabled Features](#9-disabled-features)
10. [Disable / Remove](#10-disable--remove)
11. [Troubleshooting](#11-troubleshooting)

## 1. Chart Structure

```yaml
# Chart.yaml
dependencies:
  - alias: logging          # → loki (Monolithic)
    name: loki
    repository: https://grafana-community.github.io/helm-charts
    version: 18.7.6          # N-1 stable (current N = 18.8.0)
  - alias: fluent-bit
    name: fluent-bit
    repository: https://ot-container-kit.github.io/helm-charts
    version: 0.0.2           # N-1 stable (current N = 0.0.3)
```

| File                  | Purpose                                                            |
|-----------------------|--------------------------------------------------------------------|
| `Chart.yaml`          | Umbrella metadata + deps (`logging` → loki, `fluent-bit`)          |
| `values.yaml`         | Base config: Monolithic mode, S3/MinIO storage, Fluent Bit pipeline |
| `values-minikube.yaml`| Minikube overlay — deltas only, deep-merged over `values.yaml`     |
| `charts/`             | Vendored subchart tgz (loki 18.7.6, fluent-bit 0.0.2)              |
| `Chart.lock`          | Pinned dependency digests                                          |

`fullnameOverride: loki` fixes the resource prefix, so the gateway is always `<namespace>/loki-gateway` and Fluent Bit can resolve it statically.

## 2. Architecture

```
                    ┌────────────────────────────────────────────┐
                    │           <namespace> (e.g. monitoring)     │
  Pods (all nodes)  │                                            │
  ────────────────► │  Fluent Bit (DaemonSet)                    │
                    │   │  tail /var/log/containers/*.log        │
                    │   │  kubernetes filter (Merge_Log On)      │
                    │   │  grep filter  (DEBUG drop, readyz)     │
                    │   │  lua filter   (INFO/DEBUG sampling)    │
                    │   ▼  loki output plugin                    │
                    │  ┌─────────────────────────────────────┐  │
                    │  │  loki-gateway (nginx) :80            │  │
                    │  └───────────────┬─────────────────────┘  │
                    │                  ▼                         │
                    │  Monolithic Loki (SingleBinary, 1× SS):   │
                    │   distributor·ingester·querier·compactor  │
                    │   ... all in the `loki` StatefulSet       │
                    │                                            │
                    │  Storage: S3/MinIO minio.ldc.opstree.dev   │
                    └────────────────────────────────────────────┘
```

- **Fluent Bit** runs as a DaemonSet on every node, tails container logs, and ships them to the Loki gateway.
- **Loki** runs as a **single binary** StatefulSet (`deploymentMode: Monolithic`, `singleBinary.replicas: 1`).
- **Storage** is external MinIO over S3 (path-style). Loki ships no MinIO itself (`minio.enabled: false`).
- `replication_factor: 1` — single copy; suited to short-retention, non-critical logs.

## 3. Prerequisites

- Helm 3 + a Kubernetes cluster (`kubectl` context configured).
- Namespace for the deployment (create it if it doesn't exist).
- External MinIO reachable at `minio.ldc.opstree.dev:9000` with bucket `o11y-logs` (chunks, ruler, admin share one bucket) and the `minioadmin` credentials from `values.yaml`.
- **ServiceMonitor CRD** (`monitoring.coreos.com/v1`) only if you enable `monitoring.serviceMonitor` (default `true` in base values) — the templates silently skip if the CRD is absent.

## 4. Deploy to a Cluster

```bash
# from the chart directory
helm dependency build .

# install / upgrade
helm upgrade --install loki . -n <namespace> -f values.yaml --create-namespace
```

> Use `--reuse-values` only on later upgrades, never on first install.

### Check status

```bash
kubectl get pods -n <namespace>
kubectl get statefulset,deployment,daemonset -n <namespace>
helm status loki -n <namespace>
```

## 5. Deploy to Minikube

Minikube needs a few overrides: no `team=o11y` tolerations / nodeSelectors, smaller resources + a 5 Gi `standard` PVC, no autoscaling, no ServiceMonitors, `dnsService: kube-dns`, and the Fluent Bit gateway host in the deploy namespace.

`values-minikube.yaml` is a **delta overlay** of `values.yaml` — it must be passed **together with** the base file:

```bash
# create namespace
kubectl create ns monitoring
kubectl config set-context --current --namespace=monitoring

# install (base + minikube overlay)
helm install loki . -f values.yaml -f values-minikube.yaml -n monitoring --wait --timeout 10m
```

Expected result (3 workloads):

```
NAME                            READY   STATUS    RESTARTS   AGE
loki-0                          2/2     Running   0          <age>
loki-gateway-xxxxxxxxxx-xxxxx   2/2     Running   0          <age>
loki-fluent-bit-xxxxx           1/1     Running   0          <age>
```

> The MinIO endpoint (`minio.ldc.opstree.dev:9000`) is reachable from the minikube node in this environment. If it isn't in yours, switch to local filesystem storage by uncommenting the `loki.storage.filesystem` block in `values-minikube.yaml` and setting `storage.type: filesystem`.

## 6. Storage & Retention

### Object storage (S3 / MinIO)

```yaml
logging:
  loki:
    storage:
      type: s3
      bucketNames:
        chunks: o11y-logs
        ruler:  o11y-logs
        admin:  o11y-logs
      s3:
        endpoint: https://minio.ldc.opstree.dev:9000
        s3ForcePathStyle: true
```

Schema: **TSDB**, `schema: v13`, index period 24h, object store S3.

### Retention & chunking

```yaml
limits_config:
  retention_period: 8h
  reject_old_samples: true
  reject_old_samples_max_age: 6h
  ingestion_rate_mb: 32
  ingestion_burst_size_mb: 32
  per_stream_rate_limit: 10MB
  per_stream_rate_limit_burst: 20MB
  split_queries_by_interval: 15m
  query_timeout: 300s
```

- Compactor handles retention + deletion: `retention_enabled: true`, worker count 10.
- Chunking: snappy encoding, WAL enabled with `flush_on_shutdown`, `chunk_target_size: 1536000` (~1.5 MB), `max_chunk_age: 10m`.
- **Local PVC:** the single binary persists its WAL on a 20 Gi RWO PVC (5 Gi `standard` on minikube).

## 7. Log Pipeline — Fluent Bit

All volume reduction happens **at the agent** (Fluent Bit) before logs reach Loki.

| Layer    | Config                                              | Effect                               |
|----------|-----------------------------------------------------|--------------------------------------|
| Input    | `tail` `/var/log/containers/*.log`                  | collect all container logs           |
| Filter   | `kubernetes` (`Merge_Log On`)                       | enrich with pod/namespace/labels     |
| Filter   | `grep` — `Exclude log (?i)DEBUG`, `/api/v1/readyz`  | hard-drop noise                      |
| Filter   | `lua` — `sampling.lua` (`sample_info`)              | drop ~50% INFO, ~95% DEBUG           |
| Output   | `loki` → `loki-gateway.<ns>.svc.cluster.local:80`   | ship with labels                     |

Labels pushed become Loki **index labels** (keep low-cardinality): `namespace`, `pod`, `container`, `service_name`, `name`, `application_group`, `rems_service`, `rems_environment`, `cluster`.

> The gateway host in the output is namespace-dependent — if you install into a namespace other than the default, update the `host` in `fluent-bit.fluent-bit.config.outputs` (base: `observability`, minikube: `monitoring`).

## 8. Verification

```bash
# Loki readiness + label discovery
kubectl exec -n monitoring deploy/loki-gateway -- sh -c \
  'wget -qO- "http://loki:3100/ready"; echo; wget -qO- "http://loki:3100/loki/api/v1/labels"'

# query ingested streams (last 5 lines of the minikube cluster label)
kubectl exec -n monitoring deploy/loki-gateway -- sh -c \
  'wget -qO- "http://loki:3100/loki/api/v1/query_range?query=%7Bcluster%3D%22minikube%22%7D&limit=5"'

# fluent-bit output health (errors should be 0)
kubectl exec -n monitoring deploy/loki-gateway -- sh -c \
  'wget -qO- "http://loki-fluent-bit:2020/api/v1/metrics"'

# S3 round-trip: all ops should return 200
kubectl exec -n monitoring deploy/loki-gateway -- sh -c \
  'wget -qO- "http://loki:3100/metrics"' | grep -E '^loki_s3_request_duration_seconds_count\{' | grep 'status_code="200"'
```

## 9. Disabled Features

| Feature | Flag | Why off |
|---------|------|---------|
| SimpleScalable targets | `backend/read/write.replicas: 0` | Monolithic mode forbids them (validation) |
| Distributed targets | `ingester/distributor/querier/...: 0` (upstream defaults) | not used in Monolithic mode |
| Chunks cache | `chunksCache.enabled: false` | no Memcached needed at this scale |
| Results cache | `resultsCache.enabled: false` | query-frontend Memcached disabled |
| Internal MinIO | `minio.enabled: false` + `ignoreMinioDeprecation: true` | external MinIO; built-in subchart deprecated (removal 2026-10-31) |
| Ruler | `ruler.enabled: false` | alerting lives in the monitoring stack |
| Bloom components / pattern ingester | `replicas: 0` / disabled | extra CPU/mem for little gain at 8h retention |
| Loki canary / test | `lokiCanary.enabled: false`, `test.enabled: false` | keep footprint minimal |

## 10. Disable / Remove

```bash
helm uninstall loki -n monitoring
```

PVCs survive uninstall — delete explicitly to wipe WAL/chunks:

```bash
kubectl get pvc -n monitoring -l app.kubernetes.io/name=logging
kubectl delete pvc -n monitoring <pvc-name>
```

## 11. Troubleshooting

| Symptom | Check |
|---------|-------|
| No logs in Grafana | `kubectl get pods -n <ns>`; fluent-bit pods Running; `kubectl logs deploy/loki-gateway -n <ns>`; fluent-bit output `errors` in `/api/v1/metrics` |
| `memberlist` DNS warnings at startup | transient — the memberlist service resolves within ~1 min on first boot (`"joining memberlist cluster succeeded"`) |
| Fluent Bit retries / dropped records at boot | expected while Loki is starting; steady-state `errors` should be 0 |
| `Cannot run ... without an object storage backend` | `backend/read/write` replicas > 0 in Monolithic mode — keep them at 0 |
| ServiceMonitor absent | CRD `monitoring.coreos.com/v1/ServiceMonitor` missing — templates skip silently |
| Old samples rejected | `reject_old_samples_max_age: 6h` — agents far behind get dropped |
| S3 403 on bucket listing | normal if a bucket policy disallows `ListBucket`; Loki only needs Get/Put/Delete on known keys |

---

### Reference docs

- Grafana Loki deployment modes: https://grafana.com/docs/loki/latest/get-started/deployment-modes/
- Grafana Community Loki chart: https://grafana-community.github.io/helm-charts
- Fluent Bit loki output plugin: https://docs.fluentbit.io/manual/pipeline/outputs/loki
