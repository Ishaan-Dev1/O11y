# VMAgent — Standalone Chart

Hand-written chart for a **standalone VMAgent**. Unlike the other charts here it wraps no upstream subchart — `templates/` is entirely local, so `helm dependency build` is not needed.

Purpose: run an agent in a **vcluster or leaf cluster** that scrapes kube-state-metrics and remote-writes to a **central VictoriaMetrics**. No VM operator required on the target cluster.

| Component | Image |
|---|---|
| VMAgent | `quay.io/opstree/victoriametrics-vmagent:v1.141.0` |

appVersion `v1.141.0` — matches the [`VictoriaMetrics`](../VictoriaMetrics/Charts/README.md) stack version.

## Contents

1. [Chart files](#1-chart-files)
2. [What gets deployed](#2-what-gets-deployed)
3. [Deploy](#3-deploy)
4. [Scrape config and REMS labels](#4-scrape-config-and-rems-labels)
5. [Key values](#5-key-values)
6. [Relationship to the other charts](#6-relationship-to-the-other-charts)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Chart files

| File | Purpose |
|---|---|
| `Chart.yaml`         | Chart metadata. **No dependencies** |
| `values.yaml`        | Image, remote-write target, scrape config, RBAC, resources |
| `templates/_helpers.tpl`      | `vmagent.name` / `vmagent.fullname` / `vmagent.labels` helpers |
| `templates/configmap.yaml`    | Renders `scrape.yaml` from `vmagent.scrapeConfigs` |
| `templates/deployment.yaml`   | The agent |
| `templates/rbac.yaml`         | ClusterRole + ClusterRoleBinding |
| `templates/serviceaccount.yaml` | ServiceAccount |

There is no `Chart.lock` and no `charts/` — this chart has **zero subchart dependencies**, which is why it renders with no preparation step at all.

## 2. What gets deployed

| Resource | Name | Purpose |
|---|---|---|
| Deployment | `<release>-vmagent` | The agent |
| ConfigMap | `<release>-vmagent-config` | `scrape.yaml` |
| ServiceAccount | `vmagent` | Agent identity |
| ClusterRole / Binding | — | Discovery + scrape access |

Resource name is `<release>-vmagent` unless `fullnameOverride` is set (it is empty by default).

The Deployment mounts an `emptyDir` at `/vmagent-data` for the **remote-write WAL buffer**. It is not a PVC — buffered samples are **lost on pod restart**. That is a deliberate trade for this use case, not an oversight.

## 3. Deploy

```bash
cd VMAgent/Charts

# no `helm dependency build` needed — no deps

helm upgrade --install vmagent . -n monitoring -f values.yaml --create-namespace
```

Verify it can reach its scrape target and its remote-write endpoint:

```bash
kubectl get pods -n monitoring
kubectl logs -n monitoring deploy/vmagent -f
```

## 4. Scrape config and REMS labels

The ConfigMap renders a standard VMAgent `scrape.yaml` from `vmagent.scrapeConfigs`. The shipped config scrapes exactly one target:

```yaml
scrape_configs:
  - job_name: kube-state-metrics
    scrape_interval: 30s
    static_configs:
      - targets:
          - "vm-kube-state-metrics.monitoring.svc.cluster.local.:8080"
```

Then applies three `metric_relabel_configs`:

| Action | Regex | Effect |
|---|---|---|
| `labeldrop` | `(uid\|container_id\|image_id)` | Drops pod-identity labels |
| `labelmap` | `label_(rems_.+)` | Copies pod labels matching `label_rems_*` up to metric labels |
| `labeldrop` | `label_rems_.+` | Removes the raw `label_rems_*` originals |

The last two are a pair: **promote** REMS pod labels into real metric labels, then **delete** the originals so you don't pay for both. Net effect — a `rems/environment` pod label arrives at VictoriaMetrics as a metric label named `rems_environment`.

> The target has a **trailing dot** (`cluster.local.:8080`). Valid FQDN form, resolves fine — but keep it consistent if you edit it; the same string appears in [`VictoriaMetrics`](../VictoriaMetrics/Charts/README.md).

## 5. Key values

| Value | Default | Notes |
|---|---|---|
| `vmagent.image` | `quay.io/opstree/victoriametrics-vmagent:v1.141.0` | internal mirror |
| `vmagent.replicaCount` | `1` | |
| `vmagent.externalLabels.cluster` | `coe-prod` | **hardcoded — change per cluster/vcluster** |
| `vmagent.remoteWrite.url` | `https://vm.opstree.net/insert/0/prometheus/api/v1/write` | central VM, over HTTPS |
| `vmagent.scrapeInterval` | `30s` | |
| `vmagent.dataDir` | `/vmagent-data` | emptyDir WAL |
| `extraArgs.promscrape.maxScrapeSize` | `200MB` | |
| `extraArgs.promscrape.dropOriginalLabels` | `"true"` | |
| `extraArgs.promscrape.streamParse` | `"true"` | |
| `vmagent.resources` | `100m`/`128Mi` req, `500m`/`512Mi` limit | |
| `vmagent.serviceAccount.create` / `name` | `true` / `vmagent` | |
| `vmagent.rbac.create` | `true` | |

> ⚠️ **`externalLabels.cluster: "coe-prod"` is hardcoded.** Every metric this agent ships is labelled `cluster="coe-prod"` regardless of where it runs. If you install this in more than one vcluster, series from different clusters **collide in central VictoriaMetrics** unless you override this per install:
> ```bash
> helm upgrade --install vmagent . -n monitoring -f values.yaml \
>   --set vmagent.externalLabels.cluster=coe-dev
> ```

Auth for the remote-write endpoint is stubbed but commented out — `basicAuth.username`/`password` and `bearerToken`. Leave them empty unless the endpoint requires it.

## 6. Relationship to the other charts

```
kube-state-metrics  ──scrape──▶  VMAgent  ──remote_write──▶  central VictoriaMetrics
(monitoring ns)                  (this chart)                    (vm.opstree.net)
```

This agent is **write-only toward the centre**. It does not need a VM operator locally, which is what makes it usable inside a vcluster.

Three relationships to keep straight:

| Chart | Relationship |
|---|---|
| [`KubeStateMetrics`](../KubeStateMetrics/Charts/README.md) | Its service is this agent's **only scrape target** — must exist in `monitoring` |
| [`VictoriaMetrics`](../VictoriaMetrics/Charts/README.md) | The **central** store; same `v1.141.0` version family |
| [`OtelCollector`](../OtelCollector/Charts/README.md) | Also scrapes KSM, but remote-writes **metrics** via `prometheusremotewrite`. Running both means KSM metrics arrive twice — via the collector and via this agent |

That last row is the one to watch: the collector's `prometheusremotewrite` exporter and this agent can both scrape the same targets. If you see duplicated series in central VM, this is why.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No metrics in central VM | Check `kubectl logs` for remote-write errors; verify egress to `vm.opstree.net` over HTTPS |
| Scrape target unreachable | KSM must be in `monitoring`. Check `vm-kube-state-metrics.monitoring.svc` resolves |
| Metrics land with the wrong `cluster` label | `externalLabels.cluster` is hardcoded `coe-prod` — override it |
| REMS labels missing | The pod must carry `rems/*` labels matching `label_rems_.+`. Check `kubectl get pod --show-labels` |
| Duplicate series in central VM | Both this agent and the OTel collector are scraping the same targets |
| Data lost on restart | Expected — the WAL is an `emptyDir`, not a PVC |
| `promscrape.maxScrapeSize` warnings | 200 MB per scrape. Raise it or reduce the number of targets |
| Agent crashes on startup | Remote-write URL unreachable at start; `retry_on_failure` is not configured on this agent |