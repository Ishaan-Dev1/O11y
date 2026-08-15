# Tempo (Monolithic) — Standalone Chart (v1.0.0)

Self-contained umbrella chart for **Grafana Tempo in Monolithic (single-binary) mode, without Kafka**. It wraps the upstream `grafana-community/tempo` chart pinned at the **N-1 stable release** (`tempo` **2.2.2** / appVersion **2.10.4**) and runs every Tempo role — **distributor, ingester, querier, compactor, query-frontend, metrics-generator** — inside a **single StatefulSet replica** running one process.

No Kafka, no external dependencies beyond object storage (S3/MinIO). Suitable for small-to-medium trace ingestion without HA.

## Table of Contents

1. [Chart Structure](#1-chart-structure)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Deploy to a Cluster](#4-deploy-to-a-cluster)
5. [Deploy to Minikube](#5-deploy-to-minikube)
6. [Receivers & Ports](#6-receivers--ports)
7. [Storage & Retention](#7-storage--retention)
8. [Metrics Generation](#8-metrics-generation)
9. [Verification](#9-verification)
10. [Disabled Features](#10-disabled-features)
11. [Disable / Remove](#11-disable--remove)
12. [Troubleshooting](#12-troubleshooting)

## 1. Chart Structure

```yaml
# Chart.yaml
dependencies:
  - name: tempo               # → tempo (Monolithic, no alias)
    repository: https://grafana-community.github.io/helm-charts
    version: 2.2.2            # N-1 stable (current N = 2.3.x)
```

| File                  | Purpose                                                          |
|-----------------------|------------------------------------------------------------------|
| `Chart.yaml`          | Umbrella metadata + dep (`tempo` → grafana-community/tempo 2.2.2) |
| `values.yaml`         | Base config: monolithic mode, S3/MinIO storage, metric generator  |
| `values-minikube.yaml`| Minikube overlay — deltas only, deep-merged over `values.yaml`    |
| `charts/`             | Vendored subchart tgz (tempo 2.2.2)                               |
| `Chart.lock`          | Pinned dependency digest                                          |

**Naming:** no `nameOverride` / `fullnameOverride` / alias — resource names flow from the release name. Install with release name `tempo` so everything is `tempo` (see `naming-convention.md` at the repo root).

## 2. Architecture

```
                       ┌──────────────────────────────────────────────┐
                       │           <namespace> (e.g. monitoring)       │
  OTLP 4317 (gRPC)  ─► │  ┌──────────────────────────────────────┐    │
  OTLP 4318 (HTTP)  ─► │  │  Tempo StatefulSet (single binary)   │    │
  Jaeger 6831/14268─►  │  │   distributor · ingester · querier    │    │
                       │  │   compactor · query-frontend          │    │
                       │  │   metrics-generator                   │    │
                       │  └───────────────┬──────────────────────┘    │
                       │                  │                            │
                       │  Storage:        │  remote_write:             │
                       │  S3/MinIO        ▼  VM insert (exemplars)     │
                       │  minio.ldc....   │  vminsert-vm.monitoring    │
                       │  bucket o11y-    │  :8480/insert/0/prometheus │
                       │  traces-dev      │                            │
                       └──────────────────────────────────────────────┘
```

- **Tempo** runs as a **single binary** StatefulSet (`replicas: 1`) — every role in one process.
- **Storage** is external MinIO over S3 (path-style). Tempo ships no MinIO itself.
- **Metrics** from the metrics-generator (service graphs + span metrics) are pushed to VictoriaMetrics insert via `remote_write`, with exemplars enabled.

## 3. Prerequisites

- Helm 3 + a Kubernetes cluster (`kubectl` context configured).
- Namespace for the deployment (create it if it doesn't exist).
- External MinIO reachable at `minio.ldc.opstree.dev:9000` with bucket `o11y-traces-dev` and the S3 credentials from `values.yaml`.

> **Security note:** `values.yaml` ships the shared MinIO dev credentials (`access_key: minioadmin` / `secret_key: ...`). Override both in a dedicated values file (or a secret + `extraEnv`) before any production use.

## 4. Deploy to a Cluster

```bash
# from the chart directory
helm dependency build .

# install / upgrade
helm upgrade --install tempo . -n <namespace> -f values.yaml --create-namespace
```

> Use `--reuse-values` only on later upgrades, never on first install.

### Check status

```bash
kubectl get pods -n <namespace>
kubectl get statefulset,deployment -n <namespace>
helm status tempo -n <namespace>
```

## 5. Deploy to Minikube

Minikube needs a few overrides: smaller resources (single node), a 5 Gi `standard` PVC, no ServiceMonitor (no Prometheus Operator).

`values-minikube.yaml` is a **delta overlay** of `values.yaml` — it must be passed **together with** the base file:

```bash
# create namespace
kubectl create ns monitoring
kubectl config set-context --current --namespace=monitoring

# install (base + minikube overlay)
helm install tempo . -f values.yaml -f values-minikube.yaml -n monitoring --wait --timeout 10m
```

Expected result:

```
NAME      READY   STATUS    RESTARTS   AGE
tempo-0   1/1     Running   0          <age>
```

> The MinIO endpoint (`minio.ldc.opstree.dev:9000`) must be reachable from the minikube node. If it isn't in yours, point `tempo.tempo.storage.trace.backend` at a local S3-compatible service or MinIO inside the cluster.

## 6. Receivers & Ports

| Receiver   | Protocol            | Endpoint         |
|------------|---------------------|------------------|
| OTLP       | gRPC                | `0.0.0.0:4317`   |
| OTLP       | HTTP                | `0.0.0.0:4318`   |
| Jaeger     | default chart ports | 6831 (UDP), 14268 (HTTP) |
| HTTP API   | HTTP                | `3200` (server, trace queries) |

- OTLP is the **primary ingress** (`4317`/`4318`).
- Jaeger receivers stay enabled — disabling them breaks the bundled service port template.
- Service is `ClusterIP` (`TCP`) — expose externally via a Gateway / NodePort / Ingress if needed.

## 7. Storage & Retention

### Object storage (S3 / MinIO)

```yaml
tempo:
  tempo:
    storage:
      trace:
        backend: s3
        s3:
          bucket: o11y-traces-dev
          endpoint: minio.ldc.opstree.dev:9000
          access_key: <override me>
          secret_key: <override me>
          insecure: false
          forcepathstyle: true
```

Backend is **S3 by default** — swap to `gcs`/`azure` for cloud-native backends by overriding the `storage.trace` block.

### Retention

```yaml
retention: 48h                      # keep traces for 2 days
overrides.defaults.compaction.block_retention: 48h
```

### Ingester & query tuning

| Area            | Setting                        | Value            |
|-----------------|--------------------------------|------------------|
| Ingester        | `trace_idle_period`            | `30s` (fast flush) |
| Ingester        | `flush_check_period`           | `30s`            |
| Ingester        | `max_block_duration`           | `30m`            |
| Ingester        | `complete_block_timeout`       | `1h`             |
| Ingester        | `max_block_bytes`              | `500MB`          |
| Querier         | `max_concurrent_queries`       | `10`             |
| Query frontend  | `concurrent_jobs`              | `1000`           |
| Query frontend  | `target_bytes_per_job`         | `100MB`          |
| Query frontend  | `trace_by_id.query_shards`     | `16`             |

### Ingestion limits

```yaml
overrides.defaults.ingestion:
  rate_limit_bytes: 15000000       # 15MB/s per tenant
  burst_size_bytes: 20000000       # 20MB burst
  max_traces_per_user: 10000
overrides.defaults.global:
  max_bytes_per_trace: 5000000     # 5MB max trace
```

### PVC

Ingester WAL persists on a **10 Gi** `ReadWriteOnce` PVC (`5 Gi` `standard` on minikube). `storageClassName: null` → cluster default (`standard` on minikube, `standard-rwo` on GKE, `gp3` on EKS, `managed-csi` on AKS).

## 8. Metrics Generation

The **metrics-generator** is enabled with two processors:

- `service_graphs` — request/service dependency graphs.
- `span_metrics` — RED metrics with dimensions `service.namespace`, `http.method`, `http.status_code`.

Output goes to VictoriaMetrics insert via `remote_write` (exemplars enabled):

```yaml
metricsGenerator:
  enabled: true
  registry:
    collection_interval: 15s
  storage:
    remote_write:
      - url: "http://vminsert-vm.monitoring.svc:8480/insert/0/prometheus/api/v1/write"
        send_exemplars: true
```

Trace local storage for metrics-generator spans: `/tmp/tempo` (registry) and `/tmp/traces` (trace storage).

## 9. Verification

```bash
# readiness
kubectl exec -n monitoring tempo-0 -- \
  curl -s http://localhost:3200/ready

# OTLP health / receivers live
kubectl exec -n monitoring tempo-0 -- \
  curl -s "http://localhost:3200/status/services" | head

# query a trace by ID (block format)
kubectl exec -n monitoring tempo-0 -- \
  curl -s "http://localhost:3200/api/traces/<trace-id>"

# metrics-generator remote_write health
kubectl exec -n monitoring tempo-0 -- \
  curl -s "http://localhost:3200/metrics" | grep -E 'prometheus_remote_write_requests_total' | head
```

Send test traces:

```bash
# OTLP HTTP (spans -> 4318)
curl -X POST -H "Content-Type: application/x-protobuf" \
  --data-binary @trace.pb \
  "http://<tempo-service>:4318/v1/traces"
```

## 10. Disabled Features

| Feature | Flag | Why off |
|---------|------|---------|
| Kafka | — | monolithic mode without Kafka (explicit design goal) |
| Tempo Query UI | `tempoQuery.enabled: false` | Jaeger-style browser UI sidecar disabled |
| ServiceMonitor | `serviceMonitor.enabled: false` | enable with a Prometheus Operator if you need scrape targets (base); off on minikube |
| Multi-tenancy | `multitenancyEnabled: false` | single tenant |
| Streaming over HTTP | `streamOverHttpEnabled: false` | gRPC streaming used |

## 11. Disable / Remove

```bash
helm uninstall tempo -n monitoring
```

PVCs survive uninstall — delete explicitly to wipe WAL/traces:

```bash
kubectl get pvc -n monitoring -l app.kubernetes.io/name=tempo
kubectl delete pvc -n monitoring <pvc-name>
```

## 12. Troubleshooting

| Symptom | Check |
|---------|-------|
| Pod crash-loops / `Unable to attach or mount volumes` | PVC storage class doesn't exist — set `tempo.persistence.storageClassName` for your platform |
| `connection refused` to MinIO | endpoint `minio.ldc.opstree.dev:9000` reachable from the pod; creds/bucket in `values.yaml` valid |
| S3 403 / `InvalidAccessKeyId` | `access_key`/`secret_key` overridden or expired — override in your own values file |
| No spans visible | confirm traces are sent to OTLP `4317`/`4318`, not the query port `3200` |
| High memory on ingester | shorten `trace_idle_period`/`flush_check_period` (already 30s); check `max_block_bytes` |
| Metrics missing in VictoriaMetrics | `vminsert-vm.monitoring.svc:8480` resolvable from the pod; `send_exemplars` needs a compatible receiver |
| Immutable selector errors on upgrade | never change release name / add `nameOverride` after first install (see `naming-convention.md`) |

---

### Reference docs

- Grafana Tempo architecture: https://grafana.com/docs/tempo/latest/tempo/architecture/
- Grafana Community Tempo chart: https://grafana-community.github.io/helm-charts
- Tempo API / OTLP endpoints: https://grafana.com/docs/tempo/latest/api_docs/
