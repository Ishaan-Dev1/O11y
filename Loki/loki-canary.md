# Loki Canary

## Overview

Loki Canary is a **synthetic monitoring** component for Grafana Loki. It continuously generates dummy log entries, sends them to Loki, queries them back, and verifies that they are successfully ingested and retrievable.

Unlike infrastructure metrics that only show whether Loki components are running, Loki Canary validates the **actual functionality of the logging service** from an end-user's perspective.

---

# Why Use Loki Canary?

Loki Canary acts as a **synthetic monitoring and early warning system** for your logging platform.

Instead of waiting for users to report that logs are missing, Canary continuously checks whether the logging pipeline is working correctly and exposes metrics that can be used for alerting.

It answers one simple question:

> **"Can I successfully write a log to Loki and read it back?"**

---

# How It Works

```text
               Loki Canary
                    │
        Generate Dummy Log
                    │
                    ▼
        HTTP Push (/loki/api/v1/push)
                    │
                    ▼
             Loki Gateway
                    │
                    ▼
             Distributor
                    │
                    ▼
              Ingester
                    │
                    ▼
           Object Storage
                    │
                    ▼
               Querier
                    │
                    ▼
          Query the Dummy Log
                    │
                    ▼
        Compare with Original Log
                    │
          ┌─────────┴─────────┐
          │                   │
          ▼                   ▼
      Success              Failure
          │                   │
          ▼                   ▼
  Healthy Pipeline      Alert / Metrics
```

---

# What Problems Does It Solve?

Loki Canary helps detect issues such as:

- Missing log entries
- Failed log ingestion
- Increased end-to-end ingestion latency
- Query failures
- Intermittent failures within the logging pipeline
- Logging service degradation before users report issues

It continuously validates that the logging platform is functioning correctly.

---

# What Does Loki Canary Provide?

- End-to-end logging pipeline health
- End-to-end write and read latency
- Missing log detection
- Write/read success verification
- Synthetic monitoring for Loki
- Metrics that can be used for alerting

Example alerts:

- Pipeline latency exceeds threshold
- Missing entries detected
- Write failures
- Query failures

---

# What Loki Canary Cannot Do

Loki Canary **does not** provide:

- Component-to-component latency
- Root cause analysis
- Gateway latency
- Distributor latency
- Ingester latency
- Querier latency
- Storage latency
- Fluent Bit internal latency
- Application-specific logging issues

It only verifies whether the **complete pipeline** is working successfully.

---

# What Happens After an Alert?

When Canary detects an issue, it tells you that **the logging service is unhealthy**, but not which component caused it.

Example workflow:

```text
Loki Canary Alert
        │
        ▼
Pipeline is unhealthy
        │
        ▼
Check Loki Dashboards
        │
        ├── Gateway Metrics
        ├── Distributor Metrics
        ├── Ingester Metrics
        ├── Querier Metrics
        ├── Storage Metrics
        └── Fluent Bit Metrics
```

Loki Canary identifies **that a problem exists**, while component metrics help identify **where the problem exists**.

---

# Impact on the Cluster

Loki Canary generates a very small amount of traffic.

Each execution performs:

- One log write
- One log query

Resource impact:

- Low CPU usage
- Low memory usage
- Minimal network traffic
- Minimal storage usage

For most production environments, the overhead is negligible.

---

# Can the Frequency Be Configured?

Yes.

The interval for generating dummy logs is configurable. You can adjust how frequently Canary sends synthetic logs depending on your monitoring requirements.

Common production intervals include:

- Every 10 seconds
- Every 15 seconds
- Every 30 seconds
- Every 60 seconds

---

# Benefits of Enabling Loki Canary

Enabling Loki Canary provides:

- Early detection of logging pipeline failures
- Faster incident response
- Continuous validation of the logging platform
- Automated alerting based on synthetic monitoring
- End-user perspective of Loki availability
- Confidence that logs are being successfully ingested and queried

---

# Should We Enable Loki Canary?

## Recommendation

**Yes, if Loki is a production-critical service.**

Loki Canary is recommended for production environments where multiple applications or teams rely on the logging platform. It provides continuous synthetic monitoring and can detect pipeline failures before users notice missing logs.

Enable Loki Canary if:

- Loki is used by multiple teams or applications.
- You want proactive alerting instead of reactive troubleshooting.
- You need to monitor the overall health of the logging service.
- You want end-to-end validation that logs can be ingested and queried successfully.

It may not be necessary for development or test environments where synthetic monitoring is not required.

---

# Summary

> **Loki Canary provides end-to-end pipeline health and latency, not component-level health or latency.**

| Capability | Loki Canary |
|------------|-------------|
| Overall pipeline health | ✅ Yes |
| End-to-end pipeline latency | ✅ Yes |
| Missing log detection | ✅ Yes |
| End-to-end write/read verification | ✅ Yes |
| Gateway health | ❌ No |
| Distributor health | ❌ No |
| Ingester health | ❌ No |
| Querier health | ❌ No |
| Component-wise latency | ❌ No |
| Root cause analysis | ❌ No |

---

# Feature Summary

| Feature | Supported |
|----------|-----------|
| End-to-end pipeline health | ✅ |
| End-to-end latency | ✅ |
| Missing log detection | ✅ |
| Alerting capability | ✅ |
| Continuous synthetic monitoring | ✅ |
| Root cause analysis | ❌ |
| Component-level latency | ❌ |
| Fluent Bit internal latency | ❌ |
| Application log validation | ❌ |

---

# Key Takeaway

Loki Canary is **not a troubleshooting tool**.

It is a **synthetic monitoring and early warning system** that continuously verifies whether the logging pipeline is functioning correctly from an end-user's perspective.

It tells you **that the logging pipeline is unhealthy**, but it does **not** identify which component is responsible. Once Canary detects an issue, the Loki component dashboards (Gateway, Distributor, Ingester, Querier, Storage, etc.) should be used to identify the root cause.

In short:

> **Loki Canary tells you whether the entire logging pipeline is healthy and how long it takes for a log to be written and retrieved, but it does not identify which Loki component is unhealthy or causing the latency.**
