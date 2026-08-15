# Tempo — POC Updated Chart (v0.4.0)

Helm-managed Tempo for LDC production, built from the **POC `tempo-updated` chart** (`tempo-distributed` 2.26.2 / appVersion 2.10.7, grafana-community repo). Replaces the previously running plain manifests (BuildPiper `helm template | kubectl apply`) with a real, adoptable Helm release while preserving existing data (`o11y-traces` bucket + ingester PVCs).

This README is self-contained — everything you need to deploy, configure, and understand this chart.

## Table of Contents

1. [Why This Chart Exists](#1-why-this-chart-exists)
2. [Chart Structure](#2-chart-structure)
3. [Architecture](#3-architecture)
4. [Deployment](#4-deployment)
5. [Storage & Retention](#5-storage--retention)
6. [Scaling & Scheduling](#6-scaling--scheduling)
7. [Trace Ingestion & Search](#7-trace-ingestion--search)
8. [Metrics & ServiceMonitors](#8-metrics--servicemonitors)
9. [Upgrade from Plain Manifests (cutover)](#9-upgrade-from-plain-manifests-cutover)
10. [Disabled Features — What Enabling Them Does](#10-disabled-features--what-enabling-them-does)
11. [Disable / Remove](#11-disable--remove)
12. [Troubleshooting](#12-troubleshooting)

## 1. Why This Chart Exists

LDC was running Tempo as **plain manifests** (no Helm ownership), which made upgrades, rollbacks, and resource naming fragile. This chart wraps the latest `tempo-distributed` (2.26.2, appVersion 2.10.7) into a Helm release named `tempo` in namespace `observability`, with resource names that **match the live deployment** (`tempo-*`), so the cutover:

- **Preserves trace data** — same S3 bucket (`o11y-traces`), same MinIO endpoint.
- **Reuses ingester PVCs** — claim name `data`, 5 Gi (see [§9](#9-upgrade-from-plain-manifests-cutover) for the immutable-PVC caveat).
- **Keeps parity** — replica counts / HPA ranges match the live run.

Key enabler — no `nameOverride` / `fullnameOverride`:

```yaml
tempo:
  global:
    dnsService: "coredns"
```

Release name `tempo` + chart alias `tempo` ⇒ `tempo.fullname` resolves to `tempo` and every resource is `tempo-*` (e.g. `tempo-ingester-0`, `tempo-gateway`, `tempo-distributor`).

> ⚠️ **Delete the old kubectl-managed `tempo` HTTPRoute before install** — it carries no Helm ownership annotations and `helm install` will fail on a name conflict:
> ```bash
> kubectl delete httproute tempo -n observability
> ```

## 2. Chart Structure

```yaml
dependencies:
  - alias: tempo            # → tempo-distributed
    name: tempo-distributed
    repository: https://grafana-community.github.io/helm-charts
    version: 2.26.2
```

| File              | Purpose                                              |
|-------------------|------------------------------------------------------|
| `Chart.yaml`      | Umbrella chart metadata + dependency (`tempo`)        |
| `values.yaml`     | All overrides — base tuning **merged** with LDC prod overrides |
| `charts/`         | Vendored subchart tgz (tempo-distributed 2.26.2)      |

> Note: `values-ldc.yaml` (bucket `o11y-traces`, replica parity, HTTPRoute) was **merged into `values.yaml`** — a single `-f values.yaml` now carries everything for LDC.

## 3. Architecture

```
                    ┌────────────────────────────────────────────────┐
                    │           observability namespace               │
  OTel Collector ──►│  tempo-gateway (nginx) :80                      │
  (https://tempo.   │   ├ /otlp/v1/traces ──► distributor :4318      │
   opstree.net)     │   ├ /jaeger/api/traces ─► distributor :14268   │
                    │   └ /api/* ──► query-frontend :3200            │
                    │                                                │
                    │  Tempo (microservices):                         │
                    │   distributor (2) · ingester (2, STS + PVC)    │
                    │   querier (2) · query-frontend (2)             │
                    │   compactor (1) · metrics-generator (1)        │
                    │   memcached (1, STS) + exporter                │
                    │                                                │
                    │  Storage: MinIO (S3) minio.ldc.opstree.dev     │
                    │   bucket o11y-traces · block_retention 48h     │
                    │  Metrics: metrics-generator ─► vminsert-vm     │
                    │   (service graphs + span metrics, exemplars)   │
                    └────────────────────────────────────────────────┘
```

- **Gateway (nginx)** fronts all HTTP: ingestion (`/otlp/v1/traces`, `/v1/traces`, `/jaeger/api/traces`) → **distributor**; everything under `/api/*` (search, query, tags) → **query-frontend**.
- **Ingester** persists to a 5 Gi PVC (StatefulSet); blocks are flushed to S3 on idle/flush/block-duration timers.
- **Metrics-generator** derives service graphs + span metrics and remote-writes to VictoriaMetrics (`vminsert-vm.monitoring.svc:8480`) with exemplars.
- **Storage** is external MinIO (S3 path-style) — Tempo ships no local MinIO.

## 4. Deployment

```bash
# dependencies are vendored — run build first only if charts/ is missing
helm dependency build .

helm upgrade --install tempo . -n observability -f values.yaml

# note: do NOT use --reuse-values on the first install
```

Pre-requisites:

- Namespace `observability`; release name `tempo`.
- External MinIO reachable at `minio.ldc.opstree.dev:9000`, bucket `o11y-traces`.
- The old `tempo` HTTPRoute deleted (see [§1](#1-why-this-chart-exists)).
- **ServiceMonitor CRD** (`monitoring.coreos.com/v1`) must exist — VictoriaMetrics operator's prometheus-converter converts them to `VMServiceScrape`.

### Ingress / route

Rendered via `extraObjects` (in-chart), named exactly `tempo`:

```yaml
tempo:
  extraObjects:
    - |
      apiVersion: gateway.networking.k8s.io/v1
      kind: HTTPRoute
      metadata: { name: tempo, namespace: observability }
      spec:
        hostnames: [tempo.opstree.net]
        parentRefs: [{ name: web-gateway, namespace: envoy-gateway-system }]
        rules:
          - backendRefs: [{ name: tempo-gateway, port: 80 }]
            matches: [{ path: { type: PathPrefix, value: / } }]
```

`tempo.opstree.net` → Envoy `web-gateway` → `tempo-gateway` Service :80 → nginx → distributor / query-frontend. The OTel collector ships to `https://tempo.opstree.net`, so this route is on the critical ingestion path — a failed Helm install that rolls back will delete it; it is recreated on the next successful install.

## 5. Storage & Retention

### Object storage (S3 / MinIO)

```yaml
tempo:
  storage:
    trace:
      backend: s3
      s3:
        bucket: o11y-traces
        endpoint: minio.ldc.opstree.dev:9000
        insecure: false
        forcepathstyle: true
```

Block list poll `10m`; search prefetch 500 traces.

### Retention (48h)

```yaml
tempo:
  compactor:
    config:
      compaction:
        block_retention: 48h          # traces kept 2 days
        compacted_block_retention: 1h
        compaction_window: 1h
        compaction_cycle: 2m
        retention_concurrency: 5
        max_block_bytes: 107374182400 # 100 GB
  overrides:
    defaults:
      compaction:
        block_retention: 48h          # global override
```

- Traces older than **48h** are deleted by the compactor (`block_retention` set in both compactor config and global overrides).
- To change retention, update **both** locations (e.g. `7d`).

### Local persistent volumes

| Component      | Claim | Size | Notes                          |
|----------------|-------|------|--------------------------------|
| ingester (×2)  | `data`| 5 Gi RWO | WAL + pending blocks (must persist across restarts) |
| memcached      | —     | (STS, memory) | 384 MB cache, `-I 2m`, `-c 1024` |

> Live LDC ran a 2 Gi claim; the chart wants 5 Gi. Because PVC size is **immutable**, the old STS + PVC were deleted during cutover and recreated at 5 Gi — only the WAL window was lost, historical traces come back from S3.

### Ingest limits (summary)

| Parameter                     | Value |
|-------------------------------|-------|
| retention (block)             | 48h   |
| ingestion rate limit          | 15 MB/s per tenant |
| burst size                    | 20 MB |
| max traces per user (in-flight)| 10000 |
| max bytes per trace           | 5 MB  |
| server HTTP read/write timeout| 120s  |

## 6. Scaling & Scheduling

| Component         | Replicas | Autoscale       | Notes |
|-------------------|----------|-----------------|-------|
| gateway           | 1        | 1–4 (HPA)       | nginx front-door |
| distributor       | 2        | 2–4 (HPA)       | scale-up only |
| ingester          | 2        | — (StatefulSet) | PDB maxUnavailable 1 |
| querier           | 2        | 2–4 (HPA)       | scale-up only |
| query-frontend    | 2        | 2–4 (HPA)       | scale-up only |
| compactor         | 1        | —               | retention/compaction |
| metrics-generator | 1        | —               | service graphs + span metrics |
| memcached         | 1        | —               | STS + exporter sidecar |

HPA `minReplicas` = live replica count so the cluster can **only scale up**, never below current capacity.

## 7. Trace Ingestion & Search

### Ingestion paths (all → gateway nginx → distributor)

| Path                       | Backend        | Port |
|----------------------------|----------------|------|
| `/otlp/v1/traces`          | distributor    | 4318 |
| `/v1/traces`               | distributor    | 4318 |
| `/jaeger/api/traces`       | distributor    | 14268 |
| gRPC OTLP (`TraceService/Export`) | distributor | 4317 |

### Search/query paths (→ gateway nginx → query-frontend)

| Path          | Purpose                          |
|---------------|----------------------------------|
| `/api/search` | Trace search (TraceQL)           |
| `/api/search/tags` | Tag/label names for the Grafana dropdowns |
| `/api/search/tag/*/values` | Tag values |
| `/api/traces/{id}` | Trace-by-ID detail view      |

> **Grafana tag dropdowns** ("Service", "Span Name", label selector) are populated from `/api/search/tags`. If labels/tags don't appear but traces do, test this endpoint directly:
> ```bash
> kubectl exec -it deploy/tempo-gateway -n observability -c nginx -- \
>   curl -s "http://localhost:8080/api/search/tags"
> ```
> A `404` means the gateway's `location ^~ /api` → query-frontend proxy is misrouted.

### Search tuning

```yaml
tempo:
  querier:
    config:
      max_concurrent_queries: 10
      search: { query_timeout: 120s }
      trace_by_id: { query_timeout: 60s }
  queryFrontend:
    config:
      max_outstanding_per_tenant: 2000
      max_retries: 2
      search: { concurrent_jobs: 1000, target_bytes_per_job: 104857600 }
      trace_by_id: { query_shards: 16 }
      metrics: { max_duration: 3h, query_backend_after: 1h }
```

## 8. Metrics & ServiceMonitors

All Tempo components are scraped via ServiceMonitor → VictoriaMetrics operator prometheus-converter → `vmagent`.

```yaml
tempo:
  metaMonitoring:
    serviceMonitor:
      enabled: true
      interval: 30s
      scrapeTimeout: 10s
    grafanaAgent:
      enabled: false
```

| ServiceMonitor          | Component          |
|-------------------------|--------------------|
| `tempo-gateway`         | gateway nginx + exporter |
| `tempo-distributor`     | distributor        |
| `tempo-ingester`        | ingester           |
| `tempo-querier`         | querier            |
| `tempo-query-frontend`  | query-frontend     |
| `tempo-metrics-generator` | metrics-generator |
| `tempo-memcached`       | memcached + exporter |

**Pre-conditions:**
```bash
kubectl get crd servicemonitors.monitoring.coreos.com          # must exist
kubectl get vmservicescrape -n observability                    # converted CRs
```

## 9. Upgrade from Plain Manifests (cutover)

The old LDC Tempo ran as plain manifests. The cutover used `adopt-tempo-helm.sh` to stamp Helm ownership annotations onto the live resources (Deployments, StatefulSets, Services, ConfigMaps, ServiceAccount, HTTPRoute, PDBs, ServiceMonitors) before `helm upgrade --install` — so Helm adopts them instead of creating duplicates.

```bash
./adopt-tempo-helm.sh                     # one-time, against live cluster
helm upgrade --install tempo . -n observability -f values.yaml
```

### Known cutover gotchas (all solved)

| Issue | Cause | Resolution |
|-------|-------|------------|
| `Service "tempo-memcached" invalid: clusterIP may not change` | live svc has a real ClusterIP, chart wants `clusterIP: None` | `kubectl delete svc tempo-memcached -n observability` before install |
| `StatefulSet "tempo-memcached" Forbidden` | `serviceName: memcached` (live) vs `tempo-memcached` (chart) — immutable | `kubectl delete sts tempo-memcached -n observability` |
| `StatefulSet "tempo-ingester" Forbidden` | PVC 2 Gi (live) vs 5 Gi (chart) — immutable | `kubectl delete sts tempo-ingester -n observability` (PVCs are recreated at 5 Gi) |
| HTTPRoute `tempo` missing | failed install rollback deletes release-owned resources | recreated automatically on successful install |
| `500 "empty ring"` during cutover | ingesters not yet joined the memberlist ring while STS was being renamed | transient; resolves once ring members rejoin (`reached_nodes=N` in logs) |

### After upgrade, sanity-check

```bash
helm list -n observability
kubectl get pods -n observability
kubectl get pvc -n observability -l app.kubernetes.io/name=tempo
kubectl get httproute tempo -n observability      # Accepted / ResolvedRefs True
kubectl get vmservicescrape -n observability
```

## 10. Disabled Features — What Enabling Them Does

### 10.1 Jaeger / Zipkin receivers (disabled)

```yaml
tempo:
  traces:
    otlp:   { http: { enabled: true }, grpc: { enabled: true } }
    jaeger: { thriftHttp: { enabled: false }, thriftBinary: { enabled: false },
              thriftCompact: { enabled: false }, grpc: { enabled: false } }
    zipkin: { enabled: false }
```

- **Off now:** only OTLP is ingested (from the OTel collector). Leaner distributor.
- **If enabled:** the distributor listens on the legacy Jaeger/Zipkin ports (e.g. thrift 14268/6831/6832, zipkin 9411) for apps that still emit those protocols.

### 10.2 Trace detail logging (`distributor.config.log_received_spans.enabled: false`)

- **Off now:** distributor doesn't log every span — avoids log noise in high-traffic.
- **If enabled (`true`):** distributor logs each received span (and optionally all attributes). Use only while debugging span ingress.

### 10.3 Grafana Agent metrics (`metaMonitoring.grafanaAgent.enabled: false`)

- **Off now:** no in-cluster Grafana Agent for metric shipping.
- **If enabled (`true`):** deploys a Grafana Agent pod that ships Tempo metrics. Not needed here because the ServiceMonitor → VM operator → vmagent path is already active.

## 11. Disable / Remove

```bash
helm uninstall tempo -n observability
```

PVCs survive uninstall — delete explicitly to wipe ingester WAL / memcached claims:

```bash
kubectl get pvc -n observability -l app.kubernetes.io/name=tempo
kubectl delete pvc -n observability <pvc-name>
```

S3 blocks (`o11y-traces`) are external and untouched by uninstall.

## 12. Troubleshooting

| Symptom                              | Check |
|--------------------------------------|-------|
| No traces in Grafana (but datasource tests OK) | `kubectl get httproute tempo -n observability` (Accepted/ResolvedRefs) — a failed Helm install deletes the route; re-install recreates it |
| Grafana tag/label dropdowns empty | test `/api/search/tags` through the gateway (see [§7](#7-trace-ingestion--search)); ensure `location ^~ /api` → query-frontend proxy |
| `500 "empty ring"` on `/v1/traces` | ingesters not in the memberlist ring yet — `kubectl logs deploy/tempo-distributor -n observability | grep memberlist`; wait for `reached_nodes=N` |
| Traces older than 2 days missing | expected — `block_retention: 48h` (see [§5](#5-storage--retention)) |
| ServiceMonitor absent | CRD missing; or check converted `vmservicescrape` (VM operator prometheus-converter) |
| Install fails on `clusterIP may not change` / STS Forbidden | stale live resources not adopted/deleted — see [§9](#9-upgrade-from-plain-manifests-cutover) |
| Metrics-generator data missing in VM | check remote_write URL (`vminsert-vm.monitoring.svc:8480`) and `send_exemplars: true`; confirm service-graphs/span-metrics processors in `overrides.defaults.metrics_generator` |
| No OTLP ingestion | verify OTel collector output endpoint `https://tempo.opstree.net` resolves and the route is healthy |

---

### Reference docs

- Grafana Community Tempo chart (2.26.x): https://grafana-community.github.io/helm-charts
- Tempo docs: https://grafana.com/docs/tempo/latest/
- VictoriaMetrics operator prometheus-converter: https://docs.victoriametrics.com/operator/api.html#prometheusconverter
