# Loki Canary

## Overview

Loki Canary is a **synthetic monitoring** component for Grafana Loki. It continuously generates dummy log entries, sends them to Loki, queries them back, and verifies that they are successfully ingested and retrievable.

Unlike infrastructure metrics that only show whether Loki components are running, Loki Canary validates the **actual functionality of the logging service** from an end-user's perspective.

---

# Why Use Loki Canary?

Loki Canary acts as an **early warning and alerting system** for your logging platform.

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

# Summary

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

It is a **synthetic monitoring and alerting system** that continuously verifies whether Loki is functioning correctly.

Think of it as the first indicator that something is wrong. Once an alert is triggered, the Loki component metrics and dashboards are used to identify the exact root cause.
