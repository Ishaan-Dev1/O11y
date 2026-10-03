# OTel Operator — Umbrella Chart

Umbrella chart for the **OpenTelemetry Operator**, which manages auto-instrumentation across the cluster. The operator itself is one dependency; the interesting part of this chart is the three `Instrumentation` CRs it ships.

| Component | Chart (version) | Image |
|---|---|---|
| Operator | `open-telemetry/opentelemetry-operator` (**0.120.0**) | `quay.io/opstree/opentelemetry-operator:0.149.0-debian13` |

Chart version `0.120.0` is the upstream *Helm chart* release; `0.149.0` is the *operator bundle*. Different versioning schemes — not expected to match.

## Contents

1. [Chart files](#1-chart-files)
2. [What gets deployed](#2-what-gets-deployed)
3. [Deploy](#3-deploy)
4. [The three Instrumentation CRs](#4-the-three-instrumentation-crs)
5. [Auto-instrumentation images](#5-auto-instrumentation-images)
6. [Key values](#6-key-values)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Chart files

| File | Purpose |
|---|---|
| `Chart.yaml`                  | Umbrella metadata + 1 dep (`opentelemetry-operator`, alias `operator`) |
| `values.yaml`                 | Operator image, RBAC, webhook certs, auto-instrumentation image pins |
| `templates/otel-instrumentation.yaml`       | Generic `Instrumentation` CR |
| `templates/coe-dev-instrumentation.yaml`    | COE dev-cluster `Instrumentation` CR |
| `templates/coe-prod-instrumentation.yaml`   | COE prod-cluster `Instrumentation` CR |
| `charts/`                     | *Generated* — vendored dep tgz via `helm dependency build .` |
| `Chart.lock`                  | *Generated* — pinned dependency digests |

The three templates live in this umbrella chart, **not** upstream — they are why this chart exists at all.

## 2. What gets deployed

| Resource | Name | Purpose |
|---|---|---|
| Deployment | `otel-operator` | The operator manager |
| ServiceAccount | `otel-operator` | Operator identity |
| Instrumentation | `otel-instrumentation` | Generic default |
| Instrumentation | `coe-dev-instrumentation` | COE dev overlay |
| Instrumentation | `coe-prod-instrumentation` | COE prod overlay |
| MutatingWebhookConfiguration | — | Injects `OTEL_*` env vars on admission |

`operator.fullnameOverride: otel-operator` pins the resource name.

## 3. Deploy

```bash
cd OtelOperator/Charts
helm dependency build .

helm upgrade --install otel-operator . -n <namespace> -f values.yaml
```

## 4. The three Instrumentation CRs

All three render the same `Instrumentation` kind but target different clusters/purposes:

| Template | Target | Notes |
|---|---|---|
| `otel-instrumentation.yaml` | Generic / default | Baseline injection rules |
| `coe-dev-instrumentation.yaml` | COE **dev** | Matches the COE_DEV collector topology |
| `coe-prod-instrumentation.yaml` | COE **prod** | Matches the LDC collector topology |

> **`crds.create: false`** in `values.yaml` — the operator does **not** install the `Instrumentation` CRD. It must already exist in the cluster (installed once by the platform, not per-release). If `helm install` succeeds but the pods crash with `no matches for kind "Instrumentation"`, the CRD is missing.

All three CRs are rendered unconditionally. If you only want one, comment the other two out in `templates/` or gate them behind a values flag — there is no toggle today.

## 5. Auto-instrumentation images

The operator injects a sidecar or agent per language. All versions are **pinned explicitly**, which is the point of this values file:

| Language | Version | Registry |
|---|---|---|
| Java   | `2.27.0`  | `ghcr.io/open-telemetry/...-java` |
| Node.js | `0.74.0` | `ghcr.io/open-telemetry/...-nodejs` |
| Go     | `0.24.0`  | `quay.io/opstree/opentelemetry-autoinstrumentation-go` |
| Python | `0.62b1`  | `ghcr.io/open-telemetry/...-python` |
| .NET   | `1.15.0`  | `ghcr.io/open-telemetry/...-dotnet` |
| Apache HTTPD | `1.0.4` | `ghcr.io/open-telemetry/...-apache-httpd` |

Java and Go use `opstree` mirrors; the rest come from upstream GHCR.

## 6. Key values

| Value | Default | Notes |
|---|---|---|
| `operator.replicaCount` | `2` | HA |
| `operator.manager.image` | `0.149.0-debian13` | internal mirror |
| `operator.crds.create` | `false` | CRD must pre-exist |
| `operator.clusterRole.create` | `false` | cluster RBAC managed externally |
| `operator.role.create` | `false` | |
| `operator.admissionWebhooks.create` | `true` | needed for injection |
| `operator.admissionWebhooks.certManager.enabled` | `false` | |
| `operator.admissionWebhooks.autoGenerateCert` | `true` | self-signed, 3650-day validity |
| `operator.securityContext` | `runAsUser/runAsGroup: 65532`, `runAsNonRoot: true` | non-root |
| `operator.affinity` | required pod **anti**-affinity on `app: otel-operator` | one per node |

`autoGenerateCert: true` with `certPeriodDays: 3650` means the webhook cert is self-signed and effectively never rotated in practice. That is fine for a cluster-internal webhook, but it means **removing the Secret forces re-issuance** — expect a brief window where injection fails.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no matches for kind "Instrumentation"` | Operator CRDs not installed. Set `crds.create: true` for the first install, or have the platform install them |
| Pods start but no `OTEL_*` env vars | Admission webhook not registered. Check the `MutatingWebhookConfiguration` exists and the cert is valid |
| Injection doesn't happen on some pods | Check the pod's labels match the `Instrumentation` CR's `selector`. Namespace limits also apply |
| Webhook failures after a reinstall | Delete the cert Secret — `recreate: false` means it won't be regenerated automatically |
| Operator pod not scheduling | Required anti-affinity needs one eligible node per replica; lower `replicaCount` if the cluster is small |
| Traces missing downstream | Instrumentation injects OTLP env vars — the target is the collector's `4317`/`4318`. See [OtelCollector](../OtelCollector/Charts/README.md) |