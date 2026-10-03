# OTelKubeEvents — ⚠️ Not Implemented

> **This chart is an empty stub.** `Chart.yaml` and `values.yaml` are both **0 bytes**. It will not install, and it deploys nothing.
>
> ```
> $ helm template t charts/otel-kube-events
> Error: validation: chart.metadata.name is required
> ```

Both files were created on 27 Aug and never written to. They were copied here from `OPSTREE/o11y/LDC/otel-kube-events/` in their original empty state — **nothing was lost in transit**, there was nothing to lose.

| File | Size | Status |
|---|---|---|
| `Chart.yaml` | 0 B | empty |
| `values.yaml` | 0 B | empty |

## What this was meant to be

An OpenTelemetry Collector deployment that gathers **Kubernetes events** (`events.k8s.io`) and ships them to Loki, alongside kube-state-metrics-style object metrics.

The intended content almost certainly exists as a **plain ConfigMap** rather than a chart:

```
OPSTREE/o11y/LDC/kube-events-cm.yaml      (5,698 bytes)
```

That file contains a complete collector config with exactly the receivers such a chart would need:

| Receiver | Purpose |
|---|---|
| `k8s_events` | Watches `events.k8s.io` via `serviceAccount` auth |
| `k8sobjects` | Watches the `events` object (`events.k8s.io`, `mode: watch`) |
| `prometheus` | Self-scrapes `127.0.0.1:8889` |

…and exports to:

| Exporter | Target |
|---|---|
| `otlphttp/loki` | `http://logging-loki-gateway.logging.svc.cluster.local:80/otlp` |
| `prometheusremotewrite` | `http://vmsingle-vm.monitoring.svc.cluster.local:8429/api/v1/write` |

## Why it doesn't match the rest of this repo

If you build this chart out from that ConfigMap, note the config assumes a **different topology** than the other charts here:

| | This config | Rest of the repo |
|---|---|---|
| Loki tenant | `X-Scope-OrgID: infra-eks-log` — **multi-tenant** | single tenant, no org header |
| Loki auth | `basicauth/loki` authenticator | no auth on the OTLP path |
| Metrics target | `vmsingle-vm` | `vminsert-vm` (see [`VictoriaMetrics`](../victoriametrics/README.md)) |
| EKS? | Org ID is named `infra-eks-log` | LDC in-cluster |

So this is an **EKS-flavoured** config sitting in the LDC directory. Before wiring it up, decide which topology it is actually meant for — the multi-tenant `X-Scope-OrgID` header in particular will not match how [`Loki`](../loki-distributed/README.md) is deployed here.

Note it also references a `basicauth/loki` authenticator, which means a `basicauth` extension (typically pulling from a Kubernetes Secret) must be added — that part is **not** in the ConfigMap.

## To actually implement this

1. Move `kube-events-cm.yaml` into `values.yaml` under a `config:` key (the shape [`OtelCollector`](../otel-collector/README.md) uses).
2. Write a real `Chart.yaml` — ideally as a dependency on `open-telemetry/opentelemetry-collector`, not a hand-rolled template.
3. Add the `basicauth` extension and its Secret reference.
4. Settle the tenant question above — `X-Scope-OrgID` presence or absence.
5. Add RBAC for `events.k8s.io` watch.

Related background reading in OPSTREE: `otel-kube-events-vs-alternatives.md`, `k8s-event-collectors-comparison.md`.