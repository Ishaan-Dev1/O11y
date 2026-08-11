# Loki + Fluent Bit — LDC Chart (v1.0.1)

Production Loki umbrella chart. Deploys a **distributed Loki** cluster (via the `logging` alias of the `loki` Helm chart) plus **Fluent Bit** as the cluster-wide DaemonSet log collector. This is the currently running LDC chart (`loki` 6.28.0 / appVersion 3.6.10).

## Table of Contents

1. [Architecture](#1-architecture)
2. [Chart Structure](#2-chart-structure)
3. [Deployment](#3-deployment)
4. [Storage & Retention](#4-storage--retention)
5. [Scaling & Scheduling](#5-scaling--scheduling)
6. [Log Pipeline — Noise Reduction](#6-log-pipeline--noise-reduction)
7. [Metrics & ServiceMonitors](#7-metrics--servicemonitors)
8. [Disable / Remove](#8-disable--remove)
9. [Troubleshooting](#9-troubleshooting)

## 1. Architecture

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

## 2. Chart Structure

```yaml
dependencies:
  - alias: logging          # → loki
    name: loki
    repository: https://grafana.github.io/helm-charts
    version: 6.28.0
  - alias: fluent-bit
    name: fluent-bit
    repository: https://ot-container-kit.github.io/helm-charts
    version: 0.0.1
```

| File              | Purpose                                              |
|-------------------|------------------------------------------------------|
| `Chart.yaml`      | Umbrella chart metadata + deps (`logging`, `fluent-bit`) |
| `values.yaml`     | All overrides — loki config, sizing, fluent-bit pipeline |
| `httproute.yaml`  | Standalone Gateway API `HTTPRoute` → `logging-loki-gateway:80` |
| `charts/`         | Vendored subchart tgz (loki 6.28.0, fluent-bit 0.0.1) |

> Release name `logging` + subchart `loki` ⇒ all resources are `logging-loki-*` (e.g. `logging-loki-ingester-0`, `logging-loki-gateway`).

## 3. Deployment

```bash
# first time (or upgrade — same command is idempotent)
helm upgrade --install logging . -n logging -f values.yaml

# note: do NOT use --reuse-values on the first install
```

Pre-requisites:

- Namespace: `logging`
- The chart creates its own `ServiceAccount`, `ClusterRole`, `ClusterRoleBinding` for Fluent Bit.
- External MinIO must be reachable at `minio.ldc.opstree.dev:9000` with bucket `o11y-logs` (chunks, ruler, admin share one bucket).
- **ServiceMonitor CRD** (`monitoring.coreos.com/v1`) must exist for the chart's ServiceMonitors to render — VictoriaMetrics operator's prometheus-converter converts them to `VMServiceScrape` so `vmagent` scrapes them.

### Gateway API route

The standalone `httproute.yaml` routes `loki.opstree.net` through the Envoy `web-gateway` (namespace `envoy-gateway-system`) to the `logging-loki-gateway` Service on port 80.

```bash
kubectl apply -f httproute.yaml
```

## 4. Storage & Retention

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

### Ingest/query limits (summary)

| Parameter                     | Value |
|-------------------------------|-------|
| retention                     | 8h    |
| reject old samples older than | 6h    |
| ingestion rate / burst        | 32 MB/s |
| per-stream rate / burst       | 10 MB / 20 MB |
| query timeout                 | 300s  |
| querier max_concurrent        | 4     |

## 5. Scaling & Scheduling

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
| bloomPlanner/BloomBuilder/BloomGateway | 0 | disabled |
| backend/read/write/singleBinary | 0 | disabled (Distributed mode) |
| patternIngester | 0      | disabled           |
| ruler, minio   | disabled | external MinIO    |
| lokiCanary     | disabled | —                 |

Tolerations: all Loki components tolerate `team=o11y NoSchedule` — they land on dedicated observability nodes. Fluent Bit additionally tolerates the control-plane taint so every node (incl. CP) is covered.

## 6. Log Pipeline — Noise Reduction

All volume reduction happens **at the agent** (Fluent Bit) before logs reach Loki — Loki cannot sample/drop at ingestion time. Two layers are used.

### 6.1 Kubernetes filter (`Merge_Log On`)

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

### 6.2 Grep filter — hard drop

```ini
[FILTER]
    Name    grep
    Match   kube.*
    Exclude log (?i)DEBUG
    Exclude log /api/v1/readyz
```

- Drops all DEBUG lines (`(?i)` = case-insensitive) — rarely useful, safe to hard-cut.
- Drops readiness-probe hits (`/api/v1/readyz`) — high-volume, zero-value noise.
- NOTE: these match the **raw log text** (`log` field), not a parsed `log_level` key. They do **not** depend on `Merge_Log On` (unlike the `log_level` variant). INFO is deliberately left for the Lua layer (probabilistic) instead of being fully dropped.

### 6.3 Lua sampling filter — probabilistic thinning

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

Verify the actual pod log format matches before relying on it. If your apps use structured logging, prefer a `Merge_Log`-based script matching `record["log_level"]` instead.

### 6.4 Output plugin — labels & shipping

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

### 6.5 Design decisions (as implemented)

| Concern                 | Decision                                                       | Why |
|-------------------------|----------------------------------------------------------------|-----|
| INFO handling           | 50% sampled by Lua (not hard-dropped)                          | keep representative INFO visibility |
| DEBUG handling          | hard-dropped by grep + 95% sampled by Lua                      | DEBUG is rarely useful |
| Health/readyz noise     | hard-dropped by grep                                           | zero-value, high-frequency |
| Aggregation server-side | not done                                                       | breaks timestamps + loses raw logs; aggregate in LogQL instead |
| Pattern ingester        | disabled                                                       | extra CPU/mem; volume already controlled at agent |
| Loki-side sampling      | n/a (Loki can't)                                               | filtering must happen at Fluent Bit |

## 7. Metrics & ServiceMonitors

Loki + Fluent Bit are both scraped via ServiceMonitor → VictoriaMetrics operator prometheus-converter → `vmagent`.

```yaml
# loki (in values.yaml, under logging:)
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

| ServiceMonitor     | Endpoint              | Path                          |
|--------------------|-----------------------|-------------------------------|
| `logging-loki`     | `http-metrics`        | `/metrics`                    |
| `logging-fluent-bit` | `http` (2020)       | `/api/v2/metrics/prometheus`  |

**Fluent Bit metrics labels:** the `node` label comes from relabeling `__meta_kubernetes_pod_node_name` — Fluent Bit itself cannot know which node it runs on (inside a pod `hostname` = pod name). Only the scraper's Kubernetes service discovery can supply it, hence the relabelings.

**Loki job label note:** the chart hardcodes a namespace-prefixed job relabeling (`logging/$1`) to keep jobs collision-free across namespaces — e.g. `job="logging/logging-loki"`. This is intentional; strip it only if you have a cross-namespace consistent naming requirement.

**Pre-conditions:**
```bash
kubectl get crd servicemonitors.monitoring.coreos.com          # must exist
kubectl get deploy -n monitoring vms-operator -o jsonpath='{.spec.template.spec.containers[0].args}'  # check -prometheusconverter.servicemonitor.enabled
kubectl get vmservicescrape -n logging                          # converted CRs
```

## 8. Disable / Remove

```bash
helm uninstall logging -n logging
kubectl delete -f httproute.yaml
```

**Persistent data** (ingester WAL/chunks, compactor, index-gateway PVCs) survives uninstall — delete the PVCs explicitly if you want to wipe it:

```bash
kubectl get pvc -n logging -l app.kubernetes.io/name=loki
kubectl delete pvc -n logging <pvc-name>
```

## 9. Troubleshooting

| Symptom                              | Check |
|--------------------------------------|-------|
| No logs in Grafana                    | `kubectl get pods -n logging`, fluent-bit pods Running; check gateway: `kubectl logs deploy/logging-loki-gateway -n logging` |
| DEBUG/readyz logs still present       | confirm the `grep` filter matches your log format (raw text vs parsed `log_level`) |
| INFO sampling not working             | verify logs literally start with `INFO:` — see 6.3 caveat |
| ServiceMonitor absent after upgrade   | CRD missing (see §7); loki template silently skips if `monitoring.coreos.com/v1/ServiceMonitor` not registered |
| `node` label missing on FB metrics    | relabelings applied? check converted `vmservicescrape logging-fluent-bit` has `relabelConfigs` with `__meta_kubernetes_pod_node_name` |
| High ingester memory                 | check `querier.max_concurrent`, chunk params, or sample harder at agent |
| Old samples rejected                 | `reject_old_samples_max_age: 6h` — agents far behind get dropped |

---

### Reference docs

- Fluent Bit Grep filter: https://docs.fluentbit.io/manual/data-pipeline/filters/grep
- Grafana Loki Helm chart: https://github.com/grafana/helm-charts/tree/main/charts/loki
- VictoriaMetrics operator prometheus-converter: https://docs.victoriametrics.com/operator/api.html#prometheusconverter
