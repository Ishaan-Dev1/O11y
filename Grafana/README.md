# Grafana Umbrella Helm Chart (Postgres 18 + Valkey)

Umbrella chart that deploys **Grafana 13.1**, a **PostgreSQL 18** backend, and **Valkey** (Redis-compatible) as the remote cache — all in one `helm install`.

| Component | Chart (version) | Image |
|---|---|---|
| Grafana | `grafana/grafana` (**10.5.14**, N-1 of latest) | `quay.io/opstree/grafana:13.1-debian13` |
| PostgreSQL | `bitnami/postgresql` (**18.8.7**) | `quay.io/opstree/managed-postgres:18-alpine3.23` |
| Valkey | `valkey/valkey` (**0.11.0**) | `docker.io/valkey/valkey:9.0.3-trixie` |
| Sidecar | (grafana chart feature) | `quay.io/opstree/k8s-sidecar:2.7.3` |

The Postgres image is a mirror of the official Docker postgres image (uid `70`, `PGDATA=/var/lib/postgresql/18/data`). The bitnami chart is configured with overrides so it drives that image instead of the bitnami one — see the `postgres:` block in `values.yaml`.

---

## 1. Prerequisites

- Kubernetes cluster + `kubectl` + Helm **v3.19+**
- (For a custom domain) an ingress controller — nginx, istio, etc.
- (For ServiceMonitor) a Prometheus/VictoriaMetrics operator stack with the `monitoring.coreos.com/v1` CRDs installed

---

## 2. Secrets — create these FIRST

The chart references secrets by name. Two of them matter here:

### 2a. `grafana-admin-credentials` — REQUIRED (manual)

The Grafana sub-chart reads admin login from this secret via `admin.existingSecret`. **It is not created by the chart — you must create it before install**, otherwise the Grafana pod will crash.

```bash
kubectl create secret generic grafana-admin-credentials \
  -n observability \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='CHANGE-ME-strong-password'
```

Referenced in `values.yaml`:

```yaml
grafana:
  admin:
    existingSecret: grafana-admin-credentials
    userKey: admin-user
    passwordKey: admin-password
```

### 2b. `grafana-postgresql` — AUTO-GENERATED (optional to pre-create)

The bitnami chart creates this secret automatically on first install (random 20-char password) with two keys: `password` (grafana user) and `postgres-password` (superuser). It feeds both Postgres itself and Grafana:

```yaml
# -> Postgres container env (usePasswordFiles: false)
# -> Grafana: GF_DATABASE_PASSWORD from grafana-postgresql:password
```

> If you want to control the password (GitOps / rotation), pre-create the secret with the same name and keys and the chart will use it:
> ```bash
> kubectl create secret generic grafana-postgresql -n observability \
>   --from-literal=password='pg-user-pass' \
>   --from-literal=postgres-password='pg-admin-pass'
> ```

### 2c. Valkey — currently NO auth

`valkey.auth.enabled` is `false` by default (no secret). For production, enable auth and pass `password=...` in the `remote_cache` connstr.

---

## 3. Deploy

```bash
cd POC/grafana

# Pull/vendor the sub-charts (after any Chart.yaml change)
helm dependency update .

# Namespace
kubectl create namespace observability

# GKE (production-style: nodepool scheduling, LoadBalancer, standard-rwo)
helm upgrade --install grafana . -n observability \
  -f values.yaml -f values-gke.yaml

# Minikube (local test: NodePort, default storage class)
helm upgrade --install grafana . -n observability \
  -f values.yaml -f values-minikube.yaml

# Verify
kubectl get pods -n observability
kubectl get svc -n observability
```

## 4. What gets deployed

| Resource | Name | Purpose |
|---|---|---|
| Grafana Deployment | `grafana` | The UI (service `grafana:80` → `3000`) |
| Postgres StatefulSet | `grafana-postgresql` | Shared database (service `grafana-postgresql:5432`) |
| Valkey Deployment | `grafana-valkey` | Remote cache / session store (service `grafana-valkey:6379`) |
| ConfigMap | `grafana-datasources` | Datasource definitions, auto-loaded by sidecar |
| Secrets | `grafana-admin-credentials`, `grafana-postgresql` | Credentials (see section 2) |

Grafana's `grafana.ini` is wired to:

```ini
[database]
type = postgres
host = grafana-postgresql.observability.svc.cluster.local:5432
name = grafana
user = grafana

[remote_cache]
type = redis
connstr = addr=grafana-valkey.observability.svc.cluster.local:6379,pool_size=100,db=0
```

---

## 5. Custom domain / `grafana.ini` host URL

Two separate things — don't confuse them:

1. **Ingress** = makes a domain actually reachable (needs an ingress controller + DNS + optional TLS).
2. **`root_url` / `domain`** = Grafana's own public URL, used for redirects, emails, OAuth callbacks.

### Steps

1. Install an ingress controller (skip if present):
   ```bash
   # GKE with nginx ingress, or istio, etc.
   helm install ingress-nginx ingress-nginx/ingress-nginx
   # minikube:
   minikube addons enable ingress
   ```

2. Point DNS: `grafana.opstree.net` → ingress-controller LoadBalancer IP.

3. TLS cert secret (only if using TLS):
   ```bash
   kubectl create secret tls grafana-tls -n observability \
     --cert=cert.pem --key=key.pem
   ```

4. Enable + set the domain in `values.yaml`:
   ```yaml
   grafana:
     ingress:
       enabled: true
       hosts:
         - grafana.opstree.net
       tls:
         - secretName: grafana-tls
           hosts:
             - grafana.opstree.net
     grafana.ini:
       server:
         root_url: https://grafana.opstree.net   # match the scheme (http/https) of your TLS setup
   ```

   When `ingress.enabled: true`, the grafana sub-chart auto-sets `server.domain` from the first host — keep `root_url` in sync manually.

> Without TLS, use `root_url: http://grafana.opstree.net` or redirects will point at `https://` and fail.

---

## 6. Datasources — what's in `values.yaml`

Datasources are defined in the `datasources:` block, rendered into a ConfigMap (`grafana-datasources`) labeled `grafana_datasource: "1"`. The **k8s-sidecar** container watches that label and loads them into Grafana automatically.

```yaml
datasources:
  list:
    - name: loki              # logs
      uid: loki
      type: loki
      url: http://loki-logging-gateway.observability.svc.cluster.local:80
      isDefault: false
    - name: tempo             # traces
      uid: tempo
      type: tempo
      url: http://tempo-gateway.observability.svc.cluster.local:80
      isDefault: false
      tracesToLogs: loki              # Tempo -> Loki correlation
      tracesToMetrics: victoriametrics
    - name: victoriametrics   # metrics (default)
      uid: victoriametrics
      type: prometheus
      url: http://vmselect-vm-stack.observability.svc.cluster.local:8481
      isDefault: true
```

The URLs are **in-cluster service DNS names**. For another environment:

- Update the `url` values to your actual services (`loki`, `tempo`, `victoriametrics`/`prometheus` endpoints), or
- Override the whole block with a per-environment values file (the block is not merged key-by-key, so override the full `datasources` list):

```yaml
# values-prod.yaml
datasources:
  list:
    - name: prometheus
      uid: prom
      type: prometheus
      url: http://prometheus.monitoring.svc.cluster.local:9090
      isDefault: true
```

```bash
helm upgrade --install grafana . -n observability -f values.yaml -f values-prod.yaml
```

Any datasource type Grafana supports (prometheus, loki, tempo, elasticsearch, mysql, etc.) can be added with the same shape (`name`, `uid`, `type`, `url`, `isDefault`).

---

## 7. Valkey metrics — the Redis Exporter (why & how)

Valkey (Redis fork) does **not** expose metrics in Prometheus format natively. The **redis exporter** (`oliver006/redis_exporter`) is a small sidecar that reads Valkey (`INFO`/`SCAN` commands) and exposes them as `/metrics` for Prometheus to scrape.

### Why enable it
- See cache hit ratio, memory/eviction, connected clients, command stats in Grafana.
- Alert on memory pressure / evictions.

### How it works (when enabled)
```
┌───────────── valkey pod ─────────────┐
│  valkey (6379)   redis_exporter (9121) │  -> /metrics
└────────────────────────────────────────┘
              │  Service grafana-valkey-metrics:9121
              │  ServiceMonitor (prometheus operator)
              ▼
         Prometheus / VictoriaMetrics
```

### Enable it

Currently `metrics.enabled: false` in `values.yaml`. Turn it on:

```yaml
valkey:
  metrics:
    enabled: true            # starts the exporter sidecar (port 9121)
    exporter:
      image:
        registry: docker.io
        repository: oliver006/redis_exporter
        tag: "v1.79.0"
    service:
      enabled: true          # grafana-valkey-metrics Service (ClusterIP:9121)
      type: ClusterIP
      ports:
        http: 9121
    serviceMonitor:
      enabled: true          # create ServiceMonitor for prometheus operator
```

Requirements for `serviceMonitor.enabled: true`:
- The `monitoring.coreos.com/v1` CRDs must be installed (kube-prometheus-stack / victoria-metrics operator).
- Prometheus must match the ServiceMonitor via its `serviceMonitorSelector` (e.g. `release: vm-stack`). If your Prometheus uses a different label, set the ServiceMonitor `labels` accordingly:

```yaml
    serviceMonitor:
      enabled: true
      labels:
        release: vm-stack   # match your prometheus serviceMonitorSelector
```

Then you can query e.g. `redis_used_memory_bytes`, `redis_connected_clients`, `redis_keyspace_hits_total` in Grafana.

---

## 8. Multi-platform deployment pattern

`values.yaml` is platform-neutral. Per-environment overrides live in `values-<platform>.yaml` and are merged on top (`-f values.yaml -f values-<platform>.yaml`, later file wins).

| File | Platform | Key differences |
|---|---|---|
| `values-gke.yaml` | GKE | `obs-node-pool` nodeSelector, tolerations, LoadBalancer service, `standard-rwo` storage |
| `values-minikube.yaml` | Minikube | NodePort (`30080`), `standard` storage |

> Note: helm merges values files, but an empty map `{}` does **not** clear a value from an earlier file — use `null` instead.

For a new platform (e.g. EKS), copy `values-gke.yaml` → `values-eks.yaml` and change the nodeSelector/tolerations/storageClass/service to match.

---

## 9. Useful commands

```bash
# See rendered manifests without applying
helm template grafana . -n observability -f values.yaml -f values-gke.yaml

# Get auto-generated postgres password
kubectl get secret grafana-postgresql -n observability \
  -o jsonpath='{.data.password}' | base64 -d; echo

# Port-forward Grafana locally (minikube/any)
kubectl port-forward -n observability svc/grafana 8080:80

# Tear down
helm uninstall grafana -n observability
```
