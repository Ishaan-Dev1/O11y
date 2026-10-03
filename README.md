# O11y

Observability stack for Kubernetes — Helm charts, manifests, dashboards, and operational docs.

## Layout

```
charts/       Helm charts, one directory per deployable unit
manifests/    plain YAML manifests (not charts)
docs/         topic documentation, grouped by component
dashboards/   Grafana dashboards
images/       screenshots referenced by docs/
```

## Charts

| Chart | What it deploys | Namespace |
|---|---|---|
| [grafana](charts/grafana/) | Grafana + datasource provisioning | `observability` |
| [loki-standalone](charts/loki-standalone/) | Single-binary Loki + Fluent Bit | `logging` |
| [loki-distributed](charts/loki-distributed/) | Loki microservices + Fluent Bit | `logging` |
| [tempo-standalone](charts/tempo-standalone/) | Single-binary Tempo | `observability` |
| [tempo-distributed](charts/tempo-distributed/) | Tempo microservices + Gateway + HTTPRoute | `observability` |
| [victoriametrics](charts/victoriametrics/) | VictoriaMetrics server (incl. KSM scrape) | `monitoring` |
| [vmagent](charts/vmagent/) | Standalone VMagent scraper | `monitoring` |
| [kube-state-metrics](charts/kube-state-metrics/) | KSM metrics server | `monitoring` |
| [otel-operator](charts/otel-operator/) | OpenTelemetry Operator + Instrumentation CRs | `observability` |
| [otel-collector](charts/otel-collector/) | OTel Collector instance + gateway | `observability` |
| [otel-kube-events](charts/otel-kube-events/) | Kubernetes events collector — **not implemented** | — |

Chart directories named `<tool>-<variant>` hold a variant; a bare name like
`grafana` or `victoriametrics` is a single-chart tool.

### Prerequisites

Charts are committed without vendored dependencies, so a fresh clone needs the
upstream repos added before anything will build:

```bash
helm repo add bitnami              https://charts.bitnami.com/bitnami
helm repo add grafana-community    https://grafana-community.github.io/helm-charts
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo add otel                 https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add ot-container-kit     https://ot-container-kit.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add valkey               https://valkey.io/valkey-helm/
helm repo add victoriametrics      https://victoriametrics.github.io/helm-charts/
helm repo update
```

Then build every chart. `otel-kube-events` is skipped — it has no `Chart.yaml`
content yet, so `helm dependency build` would fail on it:

```bash
for c in charts/*/; do
  [ -s "$c/Chart.yaml" ] && helm dependency build "$c"
done
```

`charts/otel-kube-events/` is empty by design — see its README.

To confirm a clone is sound before deploying:

```bash
for c in charts/*/; do
  [ -s "$c/Chart.yaml" ] && helm template t "$c" >/dev/null && echo "ok  $c"
done
```

All charts except `otel-kube-events` render clean.

### Quick start

```bash
helm dependency build charts/loki-distributed
helm upgrade --install loki charts/loki-distributed -n logging --create-namespace
```

Each chart's README carries its own install command, values overrides, and
verification steps. Start there rather than here.

### Upgrading from plain manifests

`tempo-distributed`, `otel-operator`, and the Loki charts were originally applied
with `kubectl apply`, so live resources lack Helm's ownership annotations. Run
the bundled adoption scripts **before** `helm upgrade --install`:

```bash
./charts/tempo-distributed/collect-live.sh observability   # snapshot current state
./charts/tempo-distributed/adopt-tempo.sh                   # stamp meta.helm.sh/* annotations
```

Both scripts only add annotations and labels — they never delete resources or
alter a spec.

## Manifests

| Path | What it is |
|---|---|
| [manifests/loki-cron](manifests/loki-cron/) | CronJob-based Loki chunk backup/restore |

Plain YAML, not a Helm chart. Apply directly with `kubectl`.

## Docs

Component guides live under `docs/`:

| Path | Subject |
|---|---|
| [docs/loki/noise-reduction.md](docs/loki/noise-reduction.md) | Log sampling, Lua processors, drop rules |
| [docs/loki/storage-tiering.md](docs/loki/storage-tiering.md) | External object-storage tiers |
| [docs/loki/loki-canary.md](docs/loki/loki-canary.md) | Canary for Loki health checks |
| [docs/loki/backup-ldc.md](docs/loki/backup-ldc.md) | LDC config comparison |
| [docs/loki/LDC-updated.md](docs/loki/LDC-updated.md) | Historical POC chart notes |
| [docs/tempo3.0.md](docs/tempo3.0.md) | Tempo 3 architecture |
| [docs/gcp-alb.md](docs/gcp-alb.md) | GCP ALB dashboard walkthrough |
| [docs/postgres_exporter/metrics.md](docs/postgres_exporter/metrics.md) | Postgres exporter metrics |

## Dashboards

[dashboards/](dashboards/) holds Grafana dashboards. These are Grafana Operator
CRDs (`dashboard.grafana.app/v2`), so deploying them requires the operator and
its CRDs to be installed in the cluster — this repo does not currently ship
them.

## Conventions

- Chart dirs are lowercase; docs and images are lowercase; component docs nest
  under `docs/<component>/`.
- Vendored `charts/*.tgz` are gitignored. Run `helm dependency build` after
  cloning.
- Never commit secrets or kubeconfigs — see `.gitignore`.