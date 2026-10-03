# OTel Collector — Umbrella Chart

Umbrella chart that deploys the **OpenTelemetry Collector** plus two scrape targets it owns. This is the **central collector** in LDC: it receives OTLP from workloads and fans out to Tempo (traces), Loki (logs), and VictoriaMetrics (metrics).

| Component | Chart (version) | Image |
|---|---|---|
| Collector | `open-telemetry/opentelemetry-collector` (**0.160.0**) | `quay.io/opstree/opentelemetry-collector:0.150.1-debian13-contrib` |
| kube-state-metrics | `prometheus-community/kube-state-metrics` (**6.3.0**) | — |
| node-exporter | `prometheus-community/prometheus-node-exporter` (**4.48.0**) | — |

> Chart version `0.160.0` and image tag `0.150.1` are different things — the former is the upstream *Helm chart* release, the latter is the *collector binary*. They are not expected to match.

## Contents

1. [Chart files](#1-chart-files)
2. [What gets deployed](#2-what-gets-deployed)
3. [Deploy](#3-deploy)
4. [Pipelines — how data flows](#4-pipelines--how-data-flows)
5. [Exporters and destinations](#5-exporters-and-destinations)
6. [Scrape targets you own](#6-scrape-targets-you-own)
7. [Key values](#7-key-values)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Chart files

| File | Purpose |
|---|---|
| `Chart.yaml`             | Umbrella metadata + 3 deps (`collector`, kube-state-metrics, node-exporter) |
| `values.yaml`            | Everything: collector image, ports, RBAC, and the full pipeline config |
| `charts/`                | *Generated* — vendored dep tgz via `helm dependency build .` |
| `Chart.lock`             | *Generated* — pinned dependency digests |

Deps are **not committed**. Run `helm dependency build .` first; without it `helm install` fails with `found in Chart.yaml, but missing in charts/ directory`.

## 2. What gets deployed

| Resource | Name | Purpose |
|---|---|---|
| Deployment | `otel-collector-collector` | The collector itself |
| Service | `otel-collector-collector` | OTLP + metrics endpoints |
| ServiceAccount | `otel-collector-collector` | Collector identity |
| ClusterRole / Binding | `otel-collector-collector` | `k8sattributes` needs pod/namespace read |
| ServiceMonitor | `otel-collector-collector` | Scrapes the collector's own metrics |

Resource names come from `collector.fullnameOverride: otel-collector-collector`.

### Ports

| Port | Name | Purpose |
|---|---|---|
| `4317` | `otlp` | OTLP **gRPC** ingest |
| `4318` | `otlp-http` | OTLP **HTTP** ingest |
| `13133` | `health-check` | `health_check` extension |
| `8889` | `metrics` | Collector self-telemetry (Prometheus) |

## 3. Deploy

```bash
cd OtelCollector/Charts
helm dependency build .

kubectl create namespace observability

helm upgrade --install otel-collector . -n observability -f values.yaml

# Verify
kubectl get pods -n observability
kubectl get svc otel-collector-collector -n observability
```

## 4. Pipelines — how data flows

The whole collector config lives under `collector.config` in `values.yaml`. Four pipelines:

| Pipeline | Receivers | Processors | Exporters |
|---|---|---|---|
| `logs` | `otlp` | `memory_limiter`, `k8sattributes/span`, `batch` | `otlphttp` → Loki, `debug` |
| `metrics` | `otlp`, `prometheus`, `spanmetrics`, `servicegraph` | `memory_limiter`, `attributes/metrics`, `transform/metrics`, `attributes`, `batch` | `prometheusremotewrite` → VM |
| `traces` | `otlp` | `memory_limiter`, `tail_sampling`, `k8sattributes/span`, `transform`, `batch/tempo` | `otlp` → Tempo |
| `traces/metrics` | `otlp` | `memory_limiter`, `k8sattributes/span`, `batch/tempo` | `spanmetrics`, `servicegraph` |

The `traces/metrics` pipeline is a **fan-out**: the same incoming spans that go to Tempo are also fed through the `spanmetrics` and `servicegraph` connectors, which is what produces RED metrics and service graphs in VictoriaMetrics without a separate collector.

Self-telemetry is scraped by the `prometheus` receiver from `127.0.0.1:8889` — the collector monitors itself.

## 5. Exporters and destinations

| Exporter | Destination | Transport |
|---|---|---|
| `otlp` | `tempo-distributor:4317` | gRPC, snappy, `tls.insecure: true` |
| `otlphttp` | `http://logging-loki-gateway.logging.svc.cluster.local/otlp` | HTTP |
| `prometheusremotewrite` | `http://vminsert-vm.monitoring.svc:8480/insert/0/prometheus/api/v1/write` | HTTP, 300 s timeout |
| `debug` | stdout | `verbosity: detailed` |

All three destinations are **in-cluster** short names, resolved in the collector's own namespace (`observability`) and `monitoring` respectively.

> The `debug` exporter is wired into the **logs** pipeline only, on purpose — it makes log-pipeline problems visible without doubling trace or metric volume. Comment it out in production if stdout noise is a problem.

> There is a sibling COE_DEV variant of this chart that sends to **external** HTTPS endpoints (`tempo.opstree.net`, `loki.opstree.net`, `vm.opstree.net`) and uses a different REMS label schema (`rems.service/*` instead of `rems/*`). It is **not** in this repo — this chart is the LDC in-cluster variant. See [OtelKubeEvents note](../OtelKubeEvents/Charts/README.md) for why the two differ.

## 6. Scrape targets you own

Two of the three dependencies exist purely to be scraped. Both are toggleable:

| Toggle | Default | What it does |
|---|---|---|
| `collector.enabled`            | `true` | The collector itself |
| `kubeStateMetrics.enabled`     | *(see values)* | KSM deployment, scraped by this collector |
| `nodeExporter.enabled`         | *(see values)* | node-exporter deployment, scraped by this collector |

If you would rather use the standalone `KubeStateMetrics` chart in this repo, set `kubeStateMetrics.enabled: false` here and point the collector's `prometheus` receiver at that instead — see [KubeStateMetrics](../KubeStateMetrics/Charts/README.md).

## 7. Key values

| Value | Default | Notes |
|---|---|---|
| `collector.image.repository` | `quay.io/opstree/opentelemetry-collector` | internal mirror |
| `collector.image.tag` | `0.150.1-debian13-contrib` | `-contrib` = full connector set, required for `spanmetrics`/`servicegraph` |
| `collector.replicaCount` | `1` | single instance; no PDB set |
| `collector.resources.limits` | `200m` / `1Gi` | |
| `collector.useGOMEMLIMIT` | `true` | Go runtime respects the memory limit |
| `collector.serviceMonitor.enabled` | `true` | `extraLabels.release: kube-prometheus-stack` |
| `collector.tolerations` | `operator=Equal value=observability effect=NoSchedule` | targets the dedicated observability pool |

`useGOMEMLIMIT: true` matters: the collector is Go, and without it a `1Gi` limit is not enforced by the runtime — the container gets OOM-killed before it tries to GC. Leave it on.

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `found in Chart.yaml, but missing in charts/ directory` | `helm dependency build .` |
| No traces in Tempo | Confirm the app sends OTLP to `4317`/`4318`, not `8889`. Check `tail_sampling` isn't dropping everything |
| No logs in Loki | Logs go out via `otlphttp` to `/otlp` — verify the Loki gateway path matches. Check the `debug` exporter output first |
| Metrics missing in VictoriaMetrics | `prometheusremotewrite` targets `vminsert-vm.monitoring.svc:8480`; confirm DNS resolves from the collector pod |
| No RED metrics / service graphs | The `spanmetrics`/`servicegraph` connectors run off `traces/metrics`. Confirm the image is the `-contrib` build |
| Collector OOMKilled | `useGOMEMLIMIT` must be `true`; also check `memory_limiter` is first in every pipeline |
| Pod not scheduling | Needs the `observability` node pool — check the toleration matches your pool's taint |