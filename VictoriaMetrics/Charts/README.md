# VictoriaMetrics — Umbrella Chart

Umbrella chart for the **VictoriaMetrics stack** in LDC production: `VMCluster` (storage + query) plus `VMAgent` (scraper) and `VMAlert` (alerting), wrapped around the upstream `victoria-metrics-k8s-stack` chart.

> The chart directory is `VictoriaMetrics/` but the **release name is `vm-stack`** — see [Naming](#2-naming--read-this-first) below.

| Component | Chart (version) |
|---|---|
| VM stack | `victoriametrics/victoria-metrics-k8s-stack` (**0.75.0**) |

appVersion `v1.141.0`.

## Contents

1. [Chart files](#1-chart-files)
2. [Naming — read this first](#2-naming--read-this-first)
3. [What gets deployed](#3-what-gets-deployed)
4. [Deploy](#4-deploy)
5. [The two overlays](#5-the-two-overlays)
6. [Relabel drops and the extra VMAgent](#6-relabel-drops-and-the-extra-vmagent)
7. [Key values](#7-key-values)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Chart files

| File | Purpose |
|---|---|
| `Chart.yaml`           | Umbrella metadata + 1 dep (`victoria-metrics-k8s-stack`, alias `vm`) |
| `values.yaml`          | VMCluster spec, VMAgent, VMAlert, KSM, node-exporter, `extraObjects` |
| `values-ksm.yaml`      | Overlay: add kube-state-metrics to an existing VM install |
| `values-ksm-only.yaml` | Overlay: deploy **only** KSM via the VM operator |
| `charts/`              | *Generated* — vendored dep tgz via `helm dependency build .` |
| `Chart.lock`           | *Generated* — pinned dependency digests |

## 2. Naming — read this first

`vm.fullnameOverride: "vm"` is set, so with release name `vm-stack` the resources are:

| Resource | Name |
|---|---|
| VMCluster | `vmcluster-vm-stack` |
| VMSelect pods | `vmselect-vm-stack-0`, `-1` |
| VMInsert pods | `vminsert-vm-stack-0`, `-1` |
| VMStorage pods | `vmstorage-vm-stack-0`, `-1` |
| VMAgent | `vmagent-vm-stack` |
| VMAlert | `vmalert-vm-stack` |
| KSM | `vm-kube-state-metrics` |
| node-exporter | `vm-prometheus-node-exporter` |

This is why other charts in this repo address the services as `vminsert-vm.monitoring.svc:8480` and `vmselect-vm-stack.observability.svc:8481` — the `vm-stack` infix is the release name. Changing the release name changes all of them.

## 3. What gets deployed

Enabled components in `values.yaml`:

| Component | Enabled | Replicas | Notes |
|---|---|---|---|
| `vmcluster` | ✅ | 2 / 2 / 2 | `vmselect` 2, `vminsert` 2, `vmstorage` 2 |
| `vmagent` | ✅ | — | scrapes ServiceMonitors / PodMonitors |
| `vmalert` | ✅ | — | `selectAllByDefault: true`, 15 s interval |
| `prometheus-node-exporter` | ✅ | — | `fullnameOverride: vm-prometheus-node-exporter` |
| `kube-state-metrics` | ❌ | — | off by default — use an overlay |
| `victoria-metrics-operator` | ❌ | — | **must already be running** |
| `vmsingle` | ❌ | — | |
| `alertmanager` | ❌ | — | |
| `grafana` / `defaultDashboards` | ❌ | — | dashboards live in `../../Dashboards` |
| `defaultRules` | ❌ (`create: false`) | — | |
| `kubeApiServer` / `kubeControllerManager` | ❌ | — | |

`vmstorage` uses `storageClassName: longhorn-restricted` — see [Troubleshooting](#8-troubleshooting) if that class is absent.

## 4. Deploy

```bash
cd VictoriaMetrics/Charts
helm dependency build .

kubectl create namespace monitoring   # must match the namespaces hard-coded in extraObjects

helm upgrade --install vm-stack . -n monitoring -f values.yaml
```

`victoria-metrics-operator: enabled: false` — the operator is **not** part of this chart. If the `VMCluster`/`VMAgent` CRDs are missing, install the operator first.

## 5. The two overlays

Both stack **on top of** `values.yaml`.

### `values-ksm.yaml` — add KSM

```bash
helm upgrade --install vm-stack . -n monitoring -f values.yaml -f values-ksm.yaml
```

Sets only `vm.kube-state-metrics.enabled: true`. For clusters that need kube-state-metrics alongside the full stack.

### `values-ksm-only.yaml` — KSM alone

```bash
helm upgrade --install vm-stack . -n monitoring -f values.yaml -f values-ksm-only.yaml
```

Disables **everything** — operator, `vmcluster`, `vmsingle`, `vmalert`, `vmagent`, `alertmanager`, node-exporter, `defaultRules`, `grafana`, and clears `extraObjects` — leaving **only** kube-state-metrics, with `vmScrape.enabled: false` so the VM operator does not create a scrape config for it.

Requires the VM operator to already be running.

> ⚠️ `values-ksm-only.yaml` sets `extraObjects: []`, which **overwrites** the base `extraObjects` list (the `vminsert-relabel-config` ConfigMap and the `ldc-agent` VMAgent). Helm replaces lists wholesale — it does not merge them element-by-element. Using this overlay on a cluster where those objects matter will remove them.

## 6. Relabel drops and the extra VMAgent

`values.yaml` ships two objects via `extraObjects`, both pinned to namespace `monitoring`:

**`vminsert-relabel-config` ConfigMap** — a drop-based relabel config applied at ingest. It removes:

- `lxc*` interfaces (LXD/LXC container interfaces, matched by `lxc[0-9a-f]{12,}`)
- ~40 high-cardinality metric families, including most `grafana_apiserver_*` and `grafana_plugin_*` buckets, `etcd_bookmark_total`, several `node_*` internals, `loki_ingester_chunk_size_bytes_bucket`, `vm_promscrape_scrapers_started_total`, various `kube_persistentvolume*` label metrics, and assorted `informer_*` histograms

This is a cardinality control, not a bug workaround — those series are expensive to store and rarely queried.

**`ldc-agent` VMAgent** — a *second* agent alongside `vmagent-vm-stack`, also remote-writing to `vminsert-vm.monitoring.svc.cluster.local.:8480`. It differs by selectors:

| Setting | `ldc-agent` | `vmagent-vm-stack` |
|---|---|---|
| `serviceScrapeSelector` | `external: "true"` | configured in `values.yaml` |
| `selectAllByDefault` | `false` | `false` |
| `useVMConfigReloader` | `true` | `true` |

The split lets a curated set of externally-exposed services be scraped separately from the main in-cluster set.

> Both remote-write URLs end in `cluster.local.:8480` — note the **trailing dot** after `local`. That is a valid fully-qualified form and resolves correctly, but it is unusual; if you ever edit these, keep it or drop it consistently across `values.yaml`, the collector, and `vmagent`.

## 7. Key values

| Value | Default | Notes |
|---|---|---|
| `vm.fullnameOverride` | `"vm"` | with release `vm-stack` → `vmselect-vm-stack` etc. |
| `vm.vmcluster.spec.retentionPeriod` | `14d` | |
| `vm.vmcluster.spec.replicationFactor` | `1` | no cross-node replication |
| `vmstorage.replicaCount` | `2` | |
| `vm.vmstorage.*.volumeClaimTemplate.spec.storageClassName` | `longhorn-restricted` | Longhorn-backed |
| `vmselect` / `vminsert` replicas | `2` / `2` | |
| `vm.vmalert.spec.selectAllByDefault` | `true` | evaluates every alert rule |
| `vm.vmagent.spec.scrapeInterval` | `30s` | |
| `vm.vmagent.spec.selectAllByDefault` | `false` | selector-driven |

`replicationFactor: 1` with `vmstorage` at 2 replicas means data is not replicated between storage nodes — losing one `vmstorage` pod loses data. Acceptable for 14-day metrics, worth knowing.

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no matches for kind "VMCluster"` | The VM operator is not installed (`vm.victoria-metrics-operator.enabled: false`). Install it separately |
| `extraObjects` land in the wrong namespace | They hard-code `namespace: monitoring`. Install into `monitoring` or edit them |
| `vmstorage` pods stuck pending | StorageClass `longhorn-restricted` missing. Confirm with `kubectl get sc longhorn-restricted` |
| Services not resolving as `vminsert-vm.monitoring.svc` | Release name changed. Resource names derive from `vm.fullnameOverride` + release name |
| A metric vanished after install | `vminsert-relabel-config` drops ~40 high-cardinality families — check that ConfigMap before assuming a bug |
| `ldc-agent` or relabel ConfigMap disappeared | `values-ksm-only.yaml` sets `extraObjects: []`, overwriting the base list |
| Grafana shows no dashboards | Expected — `grafana.enabled: false` here. Grafana lives in its own chart (`../../Grafana`) |
| High cardinality / slow queries | Retention is 14 d and ingest drops are aggressive; check whether you actually need the dropped series |