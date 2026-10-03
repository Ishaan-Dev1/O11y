# KubeStateMetrics — Standalone Chart

Standalone **kube-state-metrics** (KSM) for clusters that need Kubernetes object state metrics without deploying the full VictoriaMetrics stack. KSM exposes what the API server knows about your objects — pod phases, deployment replica counts, node status — as Prometheus metrics.

| Component | Chart (version) | Image |
|---|---|---|
| kube-state-metrics | `prometheus-community/kube-state-metrics` (**5.30.0**) | `quay.io/opstree/kube-state-metrics:2.18.0-debian13` |

Chart version `5.30.0` is the upstream *Helm chart* release; the image tag `2.18.0-debian13` is the *KSM binary*. Different versioning schemes — not expected to match.

## Contents

1. [Chart files](#1-chart-files)
2. [What gets deployed](#2-what-gets-deployed)
3. [Deploy](#3-deploy)
4. [Why the name is `vm-kube-state-metrics`](#4-why-the-name-is-vm-kube-state-metrics)
5. [Configuration](#5-configuration)
6. [Relationship to the other charts](#6-relationship-to-the-other-charts)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Chart files

| File | Purpose |
|---|---|
| `Chart.yaml` | Umbrella metadata + 1 dep (`kube-state-metrics`) |
| `values.yaml` | Image mirror, allowlists, RBAC, probes, Service annotations |
| `charts/` | *Generated* — vendored dep tgz via `helm dependency build .` |
| `Chart.lock` | *Generated* — pinned dependency digests |

## 2. What gets deployed

| Resource | Name | Purpose |
|---|---|---|
| Deployment | `vm-kube-state-metrics` | The KSM server |
| Service | `vm-kube-state-metrics` | Metrics endpoint `:8080` |
| ServiceAccount | `kube-sa` | KSM identity |
| ClusterRole / Binding | `vm-kube-state-metrics` | Read-only on all KSM resources |

## 3. Deploy

```bash
cd KubeStateMetrics/Charts
helm dependency build .

helm upgrade --install kube-state-metrics . -n monitoring -f values.yaml --create-namespace
```

## 4. Why the name is `vm-kube-state-metrics`

`kube-state-metrics.fullnameOverride: "vm-kube-state-metrics"` is set, so the resource is named `vm-kube-state-metrics` rather than the default `kube-state-metrics`.

This is deliberate — other charts hard-code that exact FQDN:

```
vm-kube-state-metrics.monitoring.svc.cluster.local:8080
```

That string appears in:

- [`VMAgent`](../VMAgent/Charts/values.yaml) — as its scrape target
- [`VictoriaMetrics`](../VictoriaMetrics/Charts/values.yaml) — the in-chart `kube-state-metrics` block, which sets the *same* override
- [`VictoriaMetrics/values-ksm-only.yaml`](../VictoriaMetrics/Charts/values-ksm-only.yaml)

**So the namespace must be `monitoring`.** A different namespace silently breaks every scraper that targets this service.

## 5. Configuration

| Value | Default | Notes |
|---|---|---|
| `kube-state-metrics.fullnameOverride` | `vm-kube-state-metrics` | see above — don't change |
| `image.registry` / `repository` | `quay.io` / `opstree/kube-state-metrics` | internal mirror |
| `image.tag` | `2.18.0-debian13` | |
| `extraArgs` `--metric-labels-allowlist` | `pods=[*]` | every pod label becomes a metric label |
| `extraArgs` `--metric-annotations-allowlist` | `pods=[*]` | every pod annotation becomes a metric label |
| `service.port` / `targetPort` | `8080` / `http-metrics` | |
| `serviceAccount.create` / `name` | `true` / `kube-sa` | |
| `rbac.create` | `true` | |

> ⚠️ `pods=[*]` on **both** allowlists makes every pod label and annotation a Prometheus label on every pod metric. That is a real cardinality cost — a label like `kubectl.kubernetes.io/last-applied-configuration` (a whole JSON manifest) becomes a label value. It is deliberate here, but if KSM's storage grows unexpectedly, this is the first thing to restrict.

The `--resources=` argument requests state for ~30 resource types (deployments, statefulsets, PVCs, leases, webhooks, …). The full list is in `values.yaml`.

The Service carries `prometheus.io/scrape: "true"` and `prometheus.io/port: "8080"` annotations, so plain annotation-based Prometheus scrapes find it without a ServiceMonitor.

## 6. Relationship to the other charts

There are **three** places KSM can come from in this repo, and they are alternatives — pick one per cluster:

| Source | Chart version | Use when |
|---|---|---|
| **This chart** | `5.30.0` | Standalone KSM, no VM stack |
| [`OtelCollector`](../OtelCollector/Charts/README.md) | `6.3.0` | The collector owns KSM as a scrape target |
| [`VictoriaMetrics`](../VictoriaMetrics/Charts/README.md) | via `victoria-metrics-k8s-stack` | VM stack owns KSM (`values-ksm.yaml` / `values-ksm-only.yaml`) |

The KSM version differs between them (`5.30.0` here vs `6.3.0` under the collector). That is not a conflict — they are separate Helm releases — but be aware you are running different KSM majors in different clusters.

If the collector already deploys KSM (`kubeStateMetrics.enabled: true`), disable it there rather than installing this chart too, or you will have two KSM services answering on different ports.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Scraper can't resolve the service | Must be in namespace `monitoring` — the FQDN is hard-coded elsewhere |
| Duplicate KSM services | This chart **and** `OtelCollector`/`VictoriaMetrics` are both deploying it. Disable one |
| `kube-state-metrics is forbidden` | `rbac.create: false` or the ClusterRole was removed. Check `kubectl auth can-i --list` for `kube-sa` |
| Metrics missing for a resource type | It's not in the `--resources=` list |
| Storage growing faster than expected | `pods=[*]` on labels + annotations. Restrict the allowlists |
| Probes failing | Both probes hit `path: /` on `8080`. KSM's own `/` may not be a valid probe target on some versions — check the pod logs first |