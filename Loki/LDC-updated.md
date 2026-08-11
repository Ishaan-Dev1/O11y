# Loki + Fluent Bit — POC Updated Chart (v1.0.2)

Updated/experimental Loki umbrella chart. Same architecture as the LDC chart but on a **newer Loki subchart** (`loki` 18.7.1 / appVersion 3.7.4, grafana-community repo) with `fullnameOverride` so the **resource names stay identical** to the running LDC chart (`logging-loki-*`). This chart is the upgrade path for LDC.

## Table of Contents

1. [Why This Chart Exists](#1-why-this-chart-exists)
2. [Chart Structure](#2-chart-structure)
3. [Deployment](#3-deployment)
4. [Storage & Retention](#4-storage--retention)
5. [Scaling & Scheduling](#5-scaling--scheduling)
6. [Log Pipeline — Noise Reduction](#6-log-pipeline--noise-reduction)
7. [Metrics & ServiceMonitors](#7-metrics--servicemonitors)
8. [Upgrade from LDC (6.28.0 → 18.7.1)](#8-upgrade-from-ldc-6280--1871)
9. [Disable / Remove](#9-disable--remove)
10. [Troubleshooting](#10-troubleshooting)

## 1. Why This Chart Exists

The LDC chart pins the `loki` subchart at `6.28.0` (grafana repo). This POC chart uses the same values but on `loki` **18.7.1** (grafana-community), proving the config renders the same names and preserves data before the LDC upgrade.

Key enabler — **`fullnameOverride: logging-loki`**:

```yaml
logging:
  # Keep resource names identical to the running LDC chart (logging-loki-*).
  fullnameOverride: logging-loki
```

Without it, v18's name helpers would produce different resource names. With it, Deployments/StatefulSets/Services match LDC exactly: `logging-loki-ingester-0/1`, `logging-loki-compactor-0`, `logging-loki-gateway`, etc.

> ⚠️ **Label difference vs LDC:** v18.7.1 sets `app.kubernetes.io/name: logging` (LDC v6.28.0 uses `loki`) because of how `fullnameOverride` feeds the name helper. This is **self-consistent** — the ServiceMonitors select the same labels the pods carry — but any external selector/ServiceMonitor hard-coded to `app.kubernetes.io/name: loki` will not match.

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

## 3. Deployment

```bash
# dependencies are vendored — but run build first if charts/ is missing
helm dependency build .

helm upgrade --install logging . -n logging -f values.yaml
```

Pre-requisites (same as LDC):

- Namespace `logging`; release name `logging`.
- External MinIO at `minio.ldc.opstree.dev:9000`, bucket `o11y-logs`.
- `monitoring.coreos.com/v1/ServiceMonitor` CRD present (else ServiceMonitors silently skip; see §7).

### Ingress / route (v18 inline vs LDC standalone)

LDC ships a standalone `httproute.yaml`. This chart carries the equivalent **inline** under `gateway.route.main` (disabled by default):

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

Set `enabled: true` (or keep the standalone `httproute.yaml` in your repo) — the two are equivalent.

### v18-specific flags

```yaml
logging:
  # rollout-operator: only needed for ingester zone-aware replication (disabled here)
  rollout_operator:
    enabled: false

  # built-in MinIO subchart is deprecated (removal 2026-10-31);
  # external MinIO is used, so keep minio.enabled: false
  ignoreMinioDeprecation: true
```

## 4. Storage & Retention

Identical to LDC — see [LDC README §4](../Loki/README.md#4-storage--retention).

- S3/MinIO: `o11y-logs` bucket, TSDB `schema: v13`, index 24h.
- Retention 8h, reject-old-samples 6h, rate limits 32 MB/s in/burst, per-stream 10 MB/20 MB.
- WAL enabled with flush-on-shutdown, snappy, `chunk_target_size: 1536000`.
- PVCs: ingester 20 Gi (×2), compactor 1 Gi, index-gateway 1 Gi — same as LDC so **PVC claims match and data is preserved** on upgrade.

## 5. Scaling & Scheduling

Identical topology to LDC (§5 there) — Distributed mode:

| Component      | Replicas | Notes |
|----------------|----------|-------|
| distributor / querier / gateway | 1 | HPA enabled (1–10 / 1–2 / 1–3) |
| ingester       | 2        | StatefulSet, 20 Gi PVC each |
| query-frontend / scheduler | 1 | HPA off / none |
| compactor / index-gateway | 1 | PVCs |
| bloom*, patternIngester, ruler, backend/read/write/singleBinary, lokiCanary, minio | 0 / off | disabled |

All components tolerate `team=o11y NoSchedule`; Fluent Bit also tolerates control-plane.

> Rendered manifest count differs slightly (49 vs LDC's 44): v18 splits gateway/memcached ServiceAccounts and services (e.g. `logging-loki-gateway-exporter`, memberlist service). PDB count differs too (1 vs 2) — component-level variance between chart versions, no functional impact on this config.

## 6. Log Pipeline — Noise Reduction

The Fluent Bit pipeline is **byte-for-byte identical** to LDC. Full explanation: [LDC README §6](../Loki/README.md#6-log-pipeline--noise-reduction).

Quick reference — the three filters:

```ini
# 1. kubernetes filter — Merge_Log On
[FILTER]  Name kubernetes  Match kube.*  Merge_Log On  Labels On  Annotations On

# 2. grep — hard drop
[FILTER]  Name grep  Match kube.*
    Exclude log (?i)DEBUG
    Exclude log /api/v1/readyz

# 3. lua — probabilistic sampling
[FILTER]  Name lua  Match kube.*  script /fluent-bit/scripts/sampling.lua  call sample_info
```

Lua script drops ~50% of `^INFO:` and ~95% of `^DEBUG:` raw-prefixed lines; everything else passes. Output ships to `logging-loki-gateway.logging.svc.cluster.local:80` with the same label set (`namespace`, `pod`, `container`, `service_name`, `name`, REMS group, `cluster=base-vcluster`).

> Same caveat as LDC: `^INFO:`/`^DEBUG:` raw prefix matching no-ops on JSON/lowercase/timestamp-prefixed logs. Verify your app's format.

## 7. Metrics & ServiceMonitors

Identical setup to LDC (§7 there):

```yaml
# loki
logging:
  monitoring:
    serviceMonitor:
      enabled: true

# fluent-bit (+ relabelings for node/pod/namespace)
fluent-bit:
  fluent-bit:
    serviceMonitor:
      enabled: true
      relabelings:
        - { sourceLabels: [__meta_kubernetes_pod_node_name], targetLabel: node, ... }
        - { sourceLabels: [__meta_kubernetes_pod_name],      targetLabel: pod, ... }
        - { sourceLabels: [__meta_kubernetes_namespace],     targetLabel: namespace, ... }
```

| ServiceMonitor        | Endpoint       | Path                         |
|-----------------------|----------------|------------------------------|
| `logging-loki`        | `http-metrics` | `/metrics`                   |
| `logging-fluent-bit`  | `http` (2020)  | `/api/v2/metrics/prometheus` |

The fluent-bit ServiceMonitor selector uses `app.kubernetes.io/name: fluent-bit` + `instance: logging`; the loki one matches the v18 label `app.kubernetes.io/name: logging`. Both select the pods they belong to (self-consistent).

Pre-conditions / verification — same as LDC:

```bash
kubectl get crd servicemonitors.monitoring.coreos.com
kubectl get deploy -n monitoring vms-operator -o jsonpath='{.spec.template.spec.containers[0].args}'; echo
kubectl get vmservicescrape -n logging
```

## 8. Upgrade from LDC (6.28.0 → 18.7.1)

This chart is designed so upgrading LDC to it is a **rolling upgrade that preserves data**:

1. **Ingester StatefulSet** keeps the same image (`quay.io/opstree/loki:3.6-debian13`), same `serviceName` (`logging-loki-ingester-headless`), and same PVC claim template (`data`, 20 Gi, RWO) → PVCs are **reused, not recreated**.
2. Names match (`fullnameOverride`) → no orphaned resources, no downtime from renames.
3. Generated config is functionally identical (S3/MinIO, retention 8h, limits). Remaining diffs are cosmetic: compactor `grpc_address`, headless FQDN in memberlist, server hardening defaults, gateway access-log-exporter sidecar.

```bash
# on LDC, from this directory
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

## 9. Disable / Remove

```bash
helm uninstall logging -n logging
```

PVCs survive uninstall — delete explicitly to wipe WAL/chunks:

```bash
kubectl get pvc -n logging -l app.kubernetes.io/name=logging
kubectl delete pvc -n logging <pvc-name>
```

## 10. Troubleshooting

Same checklist as [LDC §9](../Loki/README.md#9-troubleshooting), plus:

| Symptom                          | Check |
|----------------------------------|-------|
| Upgrade created `loki-*` names   | `fullnameOverride: logging-loki` missing/wrong in values |
| Old ServiceMonitors match nothing| v18 label is `app.kubernetes.io/name: logging`, not `loki` (see §1) |
| `logging-fluent-bit` ServiceMonitor absent | fluent-bit chart guard needs `monitoring.coreos.com/v1` registered |
| Ingester PVC recreated on upgrade| compare claim template (name `data`, 20 Gi, RWO) against LDC — must match exactly |

---

### Reference docs

- Fluent Bit Grep filter: https://docs.fluentbit.io/manual/data-pipeline/filters/grep
- Grafana Community Loki chart (18.x): https://grafana-community.github.io/helm-charts
- VictoriaMetrics operator prometheus-converter: https://docs.victoriametrics.com/operator/api.html#prometheusconverter
