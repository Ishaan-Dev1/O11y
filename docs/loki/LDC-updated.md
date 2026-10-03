# Loki + Fluent Bit — POC Updated Chart (v1.0.2)

Updated/experimental Loki umbrella chart. Same architecture and behaviour as the LDC Loki chart but on a **newer Loki subchart** (`loki` 18.7.1 / appVersion 3.7.4, grafana-community repo) with `fullnameOverride` so the **resource names stay identical** to the LDC chart (`logging-loki-*`). This chart is the upgrade path for LDC.

This README is self-contained — everything you need to deploy, configure, and understand this chart.

## Table of Contents

1. [Why This Chart Exists](#1-why-this-chart-exists)
2. [Chart Structure](#2-chart-structure)
3. [Architecture](#3-architecture)
4. [Deployment](#4-deployment)
5. [Storage & Retention](#5-storage--retention)
6. [Scaling & Scheduling](#6-scaling--scheduling)
7. [Log Pipeline — Noise Reduction](#7-log-pipeline--noise-reduction)
8. [Disabled Features — What Enabling Them Does](#8-disabled-features--what-enabling-them-does)
9. [Metrics & ServiceMonitors](#9-metrics--servicemonitors)
10. [Upgrade from LDC (6.28.0 → 18.7.1)](#10-upgrade-from-ldc-6280--1871)
11. [Disable / Remove](#11-disable--remove)
12. [Troubleshooting](#12-troubleshooting)

## 1. Why This Chart Exists

The LDC chart pins the `loki` subchart at `6.28.0` (grafana repo). This POC chart uses the same values on `loki` **18.7.1** (grafana-community), proving the config renders the same names and preserves data before the LDC upgrade.

Key enabler — **`fullnameOverride: logging-loki`**:

```yaml
logging:
  # Keep resource names identical to the running LDC chart (logging-loki-*).
  fullnameOverride: logging-loki
```

> ⚠️ **Label difference vs LDC:** v18.7.1 sets `app.kubernetes.io/name: logging` (LDC v6.28.0 uses `loki`) because `loki.name` in v18 resolves to the alias name (`logging`) instead of the hardcoded `"loki"`. This is **self-consistent** — ServiceMonitors select the same labels the pods carry — but any external selector/ServiceMonitor hard-coded to `app.kubernetes.io/name: loki` will not match.

## 2. Chart Structure

```yaml
dependencies:
  - alias: logging          # → loki
    name: loki
    repository: https://grafana-community.github.io/helm-charts
    version: 18.7.1
  - alias: fluent-bit
    name: fluent-bit
    repository: https://ot-container-kit.github.io/helm-charts
    version: 0.0.1
```

| File              | Purpose                                              |
|-------------------|------------------------------------------------------|
| `Chart.yaml`      | Umbrella chart metadata + deps (`logging`, `fluent-bit`) |
| `values.yaml`     | All overrides + `fullnameOverride`, inline route, v18-specific flags |
| `charts/`         | Vendored subchart tgz (loki 18.7.1, fluent-bit 0.0.1) |

Release name `logging` + `fullnameOverride` ⇒ all resources are `logging-loki-*` (e.g. `logging-loki-ingester-0`, `logging-loki-gateway`, `logging-fluent-bit`).

## 3. Architecture

```
                    ┌────────────────────────────────────────────┐
                    │            logging namespace               │
  Pods (all nodes)  │                                            │
  ────────────────► │  Fluent Bit (DaemonSet)                    │
                    │   │  tail /var/log/containers/*.log        │
                    │   │  kubernetes filter (Merge_Log On)      │
                    │   │  grep filter  (DEBUG drop, readyz)     │
                    │   │  lua filter   (INFO/DEBUG sampling)    │
                    │   │                                        │
                    │   ▼  loki output plugin                    │
                    │  ┌─────────────────────────────────────┐  │
                    │  │  logging-loki-gateway (nginx) :80    │  │
                    │  └───────────────┬─────────────────────┘  │
                    │                  ▼                         │
                    │  Distributed Loki (replication_factor 1):  │
                    │   distributor · ingester (2) · querier (1) │
                    │   query-frontend · query-scheduler         │
                    │   compactor · index-gateway                │
                    │                                            │
                    │  Storage: MinIO (S3)  minio.ldc.opstree.dev│
                    └────────────────────────────────────────────┘
```

- **Fluent Bit** runs as a DaemonSet on every node (including control-plane via toleration), tails container logs, and ships them to the Loki gateway.
- **Loki** runs in Distributed mode — microservices, not single binary.
- **Storage** is external MinIO over S3 (path-style). Loki ships no MinIO itself (`minio.enabled: false`).
- `replication_factor: 1` — single copy; suitable for non-critical, short-retention log retention.

## 4. Deployment

```bash
# dependencies are vendored — but run build first if charts/ is missing
helm dependency build .

helm upgrade --install logging . -n logging -f values.yaml

# note: do NOT use --reuse-values on the first install
```

Pre-requisites:

- Namespace `logging`; release name `logging`.
- The chart creates its own `ServiceAccount`, `ClusterRole`, `ClusterRoleBinding` for Fluent Bit.
- External MinIO reachable at `minio.ldc.opstree.dev:9000` with bucket `o11y-logs` (chunks, ruler, admin share one bucket).
- **ServiceMonitor CRD** (`monitoring.coreos.com/v1`) must exist for the chart's ServiceMonitors to render — VictoriaMetrics operator's prometheus-converter converts them to `VMServiceScrape` so `vmagent` scrapes them.

### Ingress / route

The Gateway API route is inline under `gateway.route.main` (disabled by default):

```yaml
logging:
  gateway:
    route:
      main:
        enabled: false          # set true to deploy the HTTPRoute with the chart
        kind: HTTPRoute
        parentRefs:
          - { group: gateway.networking.k8s.io, kind: Gateway, name: web-gateway, namespace: envoy-gateway-system }
        hostnames: [loki.opstree.net]
```

Set `enabled: true` to route `loki.opstree.net` through the Envoy `web-gateway` to the `logging-loki-gateway` Service on port 80. (LDC ships the same route as a standalone `httproute.yaml` — either form works.)

## 5. Storage & Retention

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

### Retention (8h)

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
  max_cache_freshness_per_query: 10m
  query_timeout: 300s
  volume_enabled: true
```

- Compactor handles retention + deletion: `retention_enabled: true`, delete worker count 10.
- Chunking: snappy encoding, WAL enabled with `flush_on_shutdown`, `chunk_target_size: 1536000` (~1.5 MB), `max_chunk_age: 10m`.

### Local persistent volumes

| Component        | Claim size | Notes                          |
|------------------|-----------|--------------------------------|
| ingester (×2)    | 20 Gi RWO  | WAL + chunk data (must persist across restarts) |
| compactor        | 1 Gi       | working directory             |
| index-gateway    | 1 Gi       | TSDB index shard cache        |

> These PVC claims exactly match the LDC chart — on upgrade the PVCs are **reused, not recreated**, so data is preserved.

### Ingest/query limits (summary)

| Parameter                     | Value |
|-------------------------------|-------|
| retention                     | 8h    |
| reject old samples older than | 6h    |
| ingestion rate / burst        | 32 MB/s |
| per-stream rate / burst       | 10 MB / 20 MB |
| query timeout                 | 300s  |
| querier max_concurrent        | 4     |

## 6. Scaling & Scheduling

Replica counts (Distributed mode):

| Component      | Replicas | Autoscale          |
|----------------|----------|--------------------|
| gateway        | 1        | 1–3 (HPA)          |
| distributor    | 1        | 1–10 (HPA)         |
| ingester       | 2        | — (StatefulSet)    |
| querier        | 1        | 1–2 (HPA)          |
| query-frontend | 1        | off (HPA disabled) |
| query-scheduler| 1        | —                  |
| compactor      | 1        | —                  |
| index-gateway  | 1        | —                  |
| bloomPlanner/bloomBuilder/bloomGateway | 0 | disabled |
| patternIngester | 0      | disabled           |
| backend/read/write/singleBinary | 0 | disabled (Distributed mode) |
| ruler, minio   | disabled | external MinIO     |
| lokiCanary     | disabled | —                  |

Tolerations: all Loki components tolerate `team=o11y NoSchedule` — they land on dedicated observability nodes. Fluent Bit additionally tolerates the control-plane taint so every node (incl. CP) is covered.

> Rendered manifest count differs slightly from LDC (49 vs 44): v18 splits gateway/memcached ServiceAccounts and services (e.g. `logging-loki-gateway-exporter`, memberlist service), and PDB count differs (1 vs 2). Component-level variance between chart versions — no functional impact on this config.

## 7. Log Pipeline — Noise Reduction

All volume reduction happens **at the agent** (Fluent Bit) before logs reach Loki — Loki cannot sample/drop at ingestion time. Two layers are used.

### 7.1 Kubernetes filter (`Merge_Log On`)

```ini
[FILTER]
    Name                kubernetes
    Match               kube.*
    K8S-Logging.Parser  On
    Keep_Log            Off
    Merge_Log           On
    Labels              On
    Annotations         On
```

`Merge_Log On` merges the JSON body into the record as top-level keys. **Required** for downstream filters that match parsed fields and for label extraction in the output plugin.

### 7.2 Grep filter — hard drop

```ini
[FILTER]
    Name    grep
    Match   kube.*
    Exclude log (?i)DEBUG
    Exclude log /api/v1/readyz
```

- Drops all DEBUG lines (`(?i)` = case-insensitive) — rarely useful, safe to hard-cut.
- Drops readiness-probe hits (`/api/v1/readyz`) — high-volume, zero-value noise.
- These match the **raw log text** (`log` field), not a parsed `log_level` key — so they don't depend on `Merge_Log On` (unlike a `log_level` variant). INFO is deliberately left for the Lua layer (probabilistic) instead of being fully dropped.

**Extending grep beyond log text:** `grep` can also exclude on any parsed key injected by the kubernetes filter — namespace, pod, service, labels — with regex, e.g.:

```ini
Exclude $kubernetes['namespace_name'] kube-system
Exclude $kubernetes['pod_name']      ^loadgen-.*
Exclude $kubernetes['labels']['app'] ^(healthcheck|metrics-exporter)$
```

This lets you drop whole classes of known-noisy workloads (system namespaces, load-test pods, healthcheck apps) without touching application code.

### 7.3 Lua sampling filter — probabilistic thinning

```ini
[FILTER]
    Name    lua
    Match   kube.*
    script  /fluent-bit/scripts/sampling.lua
    call    sample_info
```

```lua
function sample_info(tag, timestamp, record)
  local msg = record["log"]
  if not msg then
    return 0, timestamp, record
  end
  if string.match(msg, "^INFO:") then
    if math.random() < 0.5 then
      return -1, timestamp, record      -- drop ~50% of INFO
    end
  elseif string.match(msg, "^DEBUG:") then
    if math.random() < 0.95 then
      return -1, timestamp, record      -- drop ~95% of DEBUG
    end
  end
  return 0, timestamp, record
end
```

**Why random sampling (not time-based):** gives a statistically even, unbiased view across time windows — bursts and quiet periods are represented proportionally, and it's stateless per-line (keeps the agent lightweight). Time-based ("1 line per N seconds") can miss bursts entirely or over-represent quiet periods.

**Caveat — raw prefix matching:** this matches `^INFO:` / `^DEBUG:` at the very start of the raw line (case-sensitive). It will silently no-op on:
- JSON-structured logs (`{"level":"info",...}`)
- lowercase prefixes (`info: ...`)
- timestamp-prefixed lines (`2026-07-20T10:00:00 INFO: ...`)

Verify the actual pod log format matches before relying on it. If your apps use structured logging, prefer a `Merge_Log`-based script matching `record["log_level"]` instead:

```lua
function sample_info(tag, timestamp, record)
  local level = record["log_level"]
  if not level then
    return 0, timestamp, record
  end
  if level == "INFO" and math.random() < 0.9 then
    return -1, timestamp, record
  elseif level == "DEBUG" and math.random() < 0.95 then
    return -1, timestamp, record
  end
  return 0, timestamp, record
end
```

### 7.4 Output plugin — labels & shipping

```ini
[OUTPUT]
    Name              loki
    Match             *
    host              logging-loki-gateway.logging.svc.cluster.local
    port              80
    labels            namespace=$kubernetes['namespace_name'],pod=$kubernetes['pod_name'],container=$kubernetes['container_name'],service_name=$kubernetes['labels']['app'],name=$kubernetes['labels']['app.kubernetes.io/name'],application_group=$kubernetes['labels']['rems/application_group'],rems_service=$kubernetes['labels']['rems/service'],rems_environment=$kubernetes['labels']['rems/environment'],cluster=base-vcluster
    remove_keys       kubernetes
```

Labels become Loki **index labels** (streams). Keep them low-cardinality: namespace, pod, container, service/app name, and REMS groupings (`rems/application_group`, `rems/service`, `rems/environment`) plus `cluster=base-vcluster`.

### 7.5 Design decisions (as implemented)

| Concern                 | Decision                                                       | Why |
|-------------------------|----------------------------------------------------------------|-----|
| INFO handling           | 50% sampled by Lua (not hard-dropped)                          | keep representative INFO visibility |
| DEBUG handling          | hard-dropped by grep + 95% sampled by Lua                      | DEBUG is rarely useful |
| Health/readyz noise     | hard-dropped by grep                                           | zero-value, high-frequency |
| Aggregation server-side | not done                                                       | breaks timestamps + loses raw logs; aggregate in LogQL instead |
| Pattern ingester        | disabled                                                       | extra CPU/mem; volume already controlled at agent |
| Loki-side sampling      | n/a (Loki can't)                                               | filtering must happen at Fluent Bit |

## 8. Disabled Features — What Enabling Them Does

This chart deliberately disables several Loki features to keep the footprint small (volume is already controlled at the agent, retention is 8h). Below is every disabled flag, what it does, and the trade-off if you enable it.

### 8.1 Tracing (`logging.loki.tracing.enabled: false`)

```yaml
logging:
  loki:
    tracing:
      enabled: false
```

- **Off now:** keeps the distributed components lean — no Jaeger/OTLP span reporting overhead.
- **If enabled (`true`):** Loki components emit their own tracing spans (distributor → ingester → querier → query-frontend) to a tracing backend. You can follow a single write/query across components to diagnose cross-component latency. Only enables if you also have a tracing backend configured (e.g. the tracing chart in this repo) and `Loki_Tracing` env pointing at it.
- **Trade-off:** small per-request CPU/memory cost + span ingestion volume. Enable only when you're debugging distributed latency — then disable again.

### 8.2 Chunks Cache (`logging.chunksCache.enabled: false`)

```yaml
logging:
  chunksCache:
    enabled: false
    batchSize: 4
    parallelism: 5
    timeout: 5s
    defaultValidity: 0s
    replicas: 1
    port: 11211
```

- **Off now:** queriers read chunks directly from S3 every time; no extra cache component running.
- **If enabled (`true`):** deploys a Memcached-backed chunks cache (1 replica, port 11211) that caches hot chunks, avoiding repeated object-store reads for the same data → lower query latency + reduced S3 load on dashboards/alerts.
- **Trade-off:** one more StatefulSet + memory per replica (its own tolerations/resources block is already present, commented out). Worth it when query volume on historical chunks is high. Note: the subchart exposes additional `indexCache` too — not used here.

### 8.3 Pattern Ingester (`patternIngester.enabled: false`, `pattern_ingester.enabled: false`)

```yaml
logging:
  patternIngester:
    enabled: false
    replicas: 0
```

```yaml
logging:
  loki:
    pattern_ingester:
      enabled: false
```

- **Off now:** saves the extra CPU/memory of a pattern-detection component; volume is already controlled at the agent, so pattern clustering buys little here.
- **If enabled (`true`):** deploys the pattern ingester which auto-detects repeated log patterns and clusters them, powering Grafana's **Explore > Patterns** view. Useful for eyeballing dominant log shapes and spotting a new/unusual pattern spiking — without writing LogQL. The `replicas` should be ≥1 when enabled (chart default is fine).
- **Trade-off:** documented per-instance CPU/memory overhead + a running component. Keep off unless you want the pattern-clustering UI feature.

### 8.4 Bloom components (`bloomPlanner/bloomBuilder/bloomGateway: replicas 0`)

```yaml
logging:
  bloomPlanner: { replicas: 0 }
  bloomBuilder: { replicas: 0 }
  bloomGateway: { replicas: 0 }
```

- **Off now:** no bloom-filter index — the newer (Grafana Cloud-era) log-acceleration feature isn't used; TSDB index + regex queries serve the 8h window fine.
- **If enabled:** planner computes bloom filters for log content and the gateway serves them to accelerate `contains()`/regex log filtering at query time — huge speedup on large log sets. Needs object-store space for the bloom index and CPU for build/plan cycles.
- **Trade-off:** substantial added components + storage. Unnecessary at this retention/volume scale.

### 8.5 Ruler (`ruler.enabled: false`)

```yaml
logging:
  ruler:
    enabled: false
```

- **Off now:** no Loki-native alerting/recording rules (those live in the monitoring stack / VictoriaMetrics instead).
- **If enabled (`true`):** deploys a ruler component that evaluates alerting/recording rules against logs. Rules would be stored in the S3 `ruler` bucket (already configured). Only needed if you want LogQL-based alerting inside Loki rather than in VM.
- **Trade-off:** one more component + rule storage; usually redundant when VMAlert already covers alerting.

### 8.6 Internal MinIO (`minio.enabled: false`)

```yaml
logging:
  minio:
    enabled: false
```

- **Off now:** external MinIO at `minio.ldc.opstree.dev` is used (shared o11y bucket `o11y-logs`). No local MinIO pods.
- **If enabled (`true`):** ships the deprecated built-in MinIO subchart (15 Gi PVC) so Loki can run against a self-contained object store. Only for dev/isolated clusters with no S3.
- **Trade-off:** storage + an extra StatefulSet, and the built-in MinIO subchart is **deprecated** (removal 2026-10-31). The chart sets `ignoreMinioDeprecation: true` to silence the warning while external MinIO is used.

### 8.7 Loki Canary (`lokiCanary.enabled: false`)

```yaml
logging:
  lokiCanary:
    enabled: false
```

- **Off now:** nothing continuously exercises the write/read path.
- **If enabled (`true`):** deploys the canary which writes known log lines and reads them back periodically, verifying the write/read path is healthy (no data loss, ingestion latency). Good early-warning signal that the sampling/filtering pipeline hasn't broken ingestion.
- **Trade-off:** one tiny Deployment writing a trickle of synthetic logs. Cheap and worth enabling in prod.

### 8.8 Zone-aware replication (`ingester.zoneAwareReplication.enabled: false` + `rollout_operator.enabled: false`)

```yaml
logging:
  ingester:
    zoneAwareReplication:
      enabled: false
  rollout_operator:
    enabled: false
```

- **Off now:** ingester rollouts go through plain StatefulSet semantics; `replication_factor: 1` anyway.
- **If enabled (`true`):** requires the **rollout-operator** (`rollout_operator.enabled: true`) — Grafana's controller for safe multi-zone ingester rollouts. Makes rolling restarts of ingesters safer across zones with minimal data loss.
- **Trade-off:** only meaningful with `replication_factor > 1` and multiple zones. Not applicable here.

### 8.9 Disabled utility replicas (singleBinary/backend/read/write, test)

```yaml
logging:
  singleBinary: { replicas: 0 }
  backend:      { replicas: 0 }
  read:         { replicas: 0 }
  write:        { replicas: 0 }
  test:         { enabled: false }
```

- **Off now:** Distributed mode is active, so the standalone single-binary and legacy backend/read/write scaling targets are zeroed; the chart test pod is disabled so `helm test` does nothing.
- **If enabled:** switch `deploymentMode` (e.g. to `SingleBinary` or `Backend/Read/Write`) — a different topology. Not relevant while running Distributed.

## 9. Metrics & ServiceMonitors

Loki + Fluent Bit are both scraped via ServiceMonitor → VictoriaMetrics operator prometheus-converter → `vmagent`.

```yaml
# loki (in values.yaml, under logging:)
logging:
  monitoring:
    serviceMonitor:
      enabled: true

# fluent-bit
fluent-bit:
  fluent-bit:
    serviceMonitor:
      enabled: true
      relabelings:            # attach node/pod/namespace to FB metrics
        - { sourceLabels: [__meta_kubernetes_pod_node_name], targetLabel: node, ... }
        - { sourceLabels: [__meta_kubernetes_pod_name], targetLabel: pod, ... }
        - { sourceLabels: [__meta_kubernetes_namespace], targetLabel: namespace, ... }
```

| ServiceMonitor        | Endpoint       | Path                          |
|-----------------------|----------------|-------------------------------|
| `logging-loki`        | `http-metrics` | `/metrics`                    |
| `logging-fluent-bit`  | `http` (2020)  | `/api/v2/metrics/prometheus`  |

**Fluent Bit metrics labels:** the `node` label comes from relabeling `__meta_kubernetes_pod_node_name` — Fluent Bit itself cannot know which node it runs on (inside a pod `hostname` = pod name). Only the scraper's Kubernetes service discovery can supply it, hence the relabelings.

**Loki job label note:** the chart hardcodes a namespace-prefixed job relabeling (`logging/$1`) to keep jobs collision-free across namespaces — e.g. `job="logging/logging-loki"`. This is intentional; strip it only if you have a cross-namespace consistent naming requirement.

**Pre-conditions:**
```bash
kubectl get crd servicemonitors.monitoring.coreos.com          # must exist
kubectl get deploy -n monitoring vms-operator -o jsonpath='{.spec.template.spec.containers[0].args}'  # check -prometheusconverter.servicemonitor.enabled
kubectl get vmservicescrape -n logging                          # converted CRs
```

## 10. Upgrade from LDC (6.28.0 → 18.7.1)

This chart is designed so upgrading LDC to it is a **rolling upgrade that preserves data**:

1. **Ingester StatefulSet** keeps the same image (`quay.io/opstree/loki:3.6-debian13`), same `serviceName` (`logging-loki-ingester-headless`), and same PVC claim template (`data`, 20 Gi, RWO) → PVCs are **reused, not recreated**.
2. Names match (`fullnameOverride`) → no orphaned resources, no downtime from renames.
3. Generated config is functionally identical (S3/MinIO, retention 8h, limits). Remaining diffs are cosmetic: compactor `grpc_address`, headless FQDN in memberlist, server hardening defaults, gateway access-log-exporter sidecar.

```bash
helm dependency update .          # ensure vendored charts match lock
helm upgrade --install logging . -n logging -f values.yaml
```

After upgrade, sanity-check:

```bash
kubectl get pods -n logging
kubectl get pvc -n logging -l app.kubernetes.io/name=logging   # ingester PVCs intact
kubectl get vmservicescrape -n logging
```

### What to verify before upgrading

- [ ] ServiceMonitor CRD + VM operator prometheus-converter (else no metrics).
- [ ] Ingester PVCs exist and are not being deleted (`maxUnavailable` default allows 1).
- [ ] Fluent-bit pods rolling with the same image tag.
- [ ] `job` label becomes `logging/...` (chart hardcodes namespace prefix) — dashboards/queries that reference old `job` values may need updating.
- [ ] Label `app.kubernetes.io/name: logging` vs `loki` — any external selectors/ServiceMonitors.

## 11. Disable / Remove

```bash
helm uninstall logging -n logging
```

PVCs survive uninstall — delete explicitly to wipe WAL/chunks:

```bash
kubectl get pvc -n logging -l app.kubernetes.io/name=logging
kubectl delete pvc -n logging <pvc-name>
```

## 12. Troubleshooting

| Symptom                              | Check |
|--------------------------------------|-------|
| No logs in Grafana                    | `kubectl get pods -n logging`, fluent-bit pods Running; check gateway: `kubectl logs deploy/logging-loki-gateway -n logging` |
| DEBUG/readyz logs still present       | confirm the `grep` filter matches your log format (raw text vs parsed `log_level`) |
| INFO sampling not working             | verify logs literally start with `INFO:` — see §7.3 caveat |
| ServiceMonitor absent after upgrade   | CRD missing (see §9); loki template silently skips if `monitoring.coreos.com/v1/ServiceMonitor` not registered |
| `node` label missing on FB metrics    | relabelings applied? check converted `vmservicescrape logging-fluent-bit` has `relabelConfigs` with `__meta_kubernetes_pod_node_name` |
| Upgrade created `loki-*` names        | `fullnameOverride: logging-loki` missing/wrong in values |
| Old ServiceMonitors match nothing     | v18 label is `app.kubernetes.io/name: logging`, not `loki` (see §1) |
| Ingester PVC recreated on upgrade      | compare claim template (name `data`, 20 Gi, RWO) against LDC — must match exactly |
| High ingester memory                 | check `querier.max_concurrent`, chunk params, or sample harder at agent |
| Old samples rejected                 | `reject_old_samples_max_age: 6h` — agents far behind get dropped |

---

### Reference docs

- Fluent Bit Grep filter: https://docs.fluentbit.io/manual/data-pipeline/filters/grep
- Grafana Community Loki chart (18.x): https://grafana-community.github.io/helm-charts
- VictoriaMetrics operator prometheus-converter: https://docs.victoriametrics.com/operator/api.html#prometheusconverter
