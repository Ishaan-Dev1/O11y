# Kubernetes Event Collectors Comparison

| Tool | Type | Deployment | Storage Backend | Filtering | Scalability | Complexity | Best For |
|------|------|------------|-----------------|-----------|-------------|------------|----------|
| **kubectl get/watch events** | CLI | Ad-hoc | Stdout/JSON | `--field-selector`, `--label-selector` | Low (manual) | Trivial | Debugging, ad-hoc inspection |
| **kube-eventer** | Sidecar/DaemonSet | In-cluster | Elasticsearch, Kafka, MQTT, SLS, DingTalk, Webhook | Regex, namespace, reason, type | Medium | Low | Simple forwarding to external systems |
| **eventrouter** | Deployment | In-cluster | Any sink (stdout, file, webhook, GCS, S3, Kafka, NATS, PubSub) | CEL expressions, namespace, type, reason | High | Medium | Flexible routing to multiple sinks |
| **Fluent Bit + K8s filter** | DaemonSet | In-cluster | Elasticsearch, Loki, Splunk, Kafka, HTTP, 30+ outputs | Labels, namespace, annotations, regex | Very High | Medium | Log aggregation pipelines |
| **Fluentd + kubernetes plugin** | DaemonSet | In-cluster | Elasticsearch, S3, GCS, Kafka, 100+ plugins | Rich filter plugins, record transformer | Very High | High | Enterprise log pipelines |
| **Promtail + Loki** | DaemonSet | In-cluster | Loki (TSDB) | Labels, pipeline stages (regex, json, labelmap) | Very High | Medium | Grafana Loki stack |
| **Vector** | DaemonSet/Sidecar | In-cluster | 50+ sinks (Loki, Elasticsearch, Splunk, Kafka, HTTP, S3) | VRL (Vector Remap Language), transforms | Very High | Medium | High-performance observability |
| **kube-state-metrics + Prometheus** | Deployment | In-cluster | Prometheus (TSDB) | PromQL, metric relabeling | High | Low | Metrics-based alerting on events |
| **event-exporter** | Deployment | In-cluster | Prometheus, stdout, webhook | Namespace, label, reason, type | High | Low | Prometheus metrics from events |
| **Custom Controller/Operator** | Deployment | In-cluster | Any (CRD, DB, external API) | Full Go control | Unlimited | Very High | Custom business logic, enrichment |

## Quick Selection Guide

```
Need simple debugging?           → kubectl get/watch events
Need to forward to Elasticsearch? → kube-eventer (simple) or Fluent Bit (robust)
Need multi-sink routing?         → eventrouter or Vector
Using Loki/Grafana?              → Promtail
Using Prometheus for alerts?     → kube-state-metrics + event-exporter
Building custom platform?        → Custom controller
Enterprise log pipeline?         → Fluentd or Vector
High throughput, low resource?   → Vector or Promtail
```

## Architecture Patterns

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│  K8s API    │────▶│  Collector   │────▶│  Storage/   │
│  Server     │     │  (DaemonSet  │     │  Analysis   │
│  (Events)   │     │  /Deployment)│     │  Backend    │
└─────────────┘     └──────────────┘     └─────────────┘
                           │
                    ┌──────┴──────┐
                    ▼             ▼
             ┌──────────┐   ┌──────────┐
             │ Filter/  │   │ Transform│
             │ Enrich   │   │ /Route   │
             └──────────┘   └──────────┘
```

## Key Differentiators

| Dimension | kube-eventer | eventrouter | Fluent Bit | Vector | Promtail |
|-----------|--------------|-------------|------------|--------|----------|
| **Config Language** | YAML | YAML | Custom (structured) | VRL (script-like) | YAML + pipeline stages |
| **Transform Capability** | Basic | CEL expressions | Lua/filters | Full VRL (rich) | Pipeline stages |
| **Memory Footprint** | ~20MB | ~30MB | ~10MB | ~15MB | ~15MB |
| **Throughput** | Medium | High | Very High | Very High | Very High |
| **Backpressure Handling** | Basic | Good | Excellent | Excellent | Good |
| **Hot Reload** | No | Yes | Yes | Yes | Yes |
| **K8s Native (CRD)** | No | No | No | No | No |

## Recommendation by Use Case

| Use Case | Recommended Tool |
|----------|-----------------|
| Dev debugging | `kubectl events --watch` |
| Single cluster → Elasticsearch | kube-eventer |
| Multi-cluster → Multiple sinks | eventrouter |
| Full observability stack (logs+metrics+traces) | Vector |
| Grafana Loki user | Promtail |
| Prometheus alerting on events | kube-state-metrics + event-exporter |
| Compliance/audit trail | eventrouter → S3/GCS (immutable) |
| High-cardinality enrichment | Custom controller |
