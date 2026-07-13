# Log Sampling & Noise Reduction — Loki + Fluent Bit

## 1. Grep Filter — Drop INFO/DEBUG/Health logs

```
[FILTER]
    Name    grep
    Match   kube.*
    Exclude log_level INFO
    Exclude log_level DEBUG
    Exclude log             /api/v1/health
```

**Why:** INFO/DEBUG logs and health-check hits are high-volume, low-value noise. Dropping them at the agent reduces ingestion volume before it ever reaches Loki.

**Impact on Loki:**
- Lower ingestion rate → less pressure on distributor/ingester.
- Smaller chunks and object storage footprint.
- Lower query cost (less irrelevant data scanned).

**Requirement:** This filter only works correctly if `Merge_Log On` is set in the `kubernetes` filter. Without merge, the parsed `log_level` field doesn't exist as a top-level key, and the grep filter has nothing to match against — the exclude rules silently no-op.

## 2. Lua Sampling Filter — Probabilistic Sampling

```
[FILTER]
    Name    lua
    Match   kube.*
    script  /fluent-bit/scripts/sampling.lua
    call    sample_info
```

**Why:** Even after removing DEBUG/INFO, some services still produce excessive repetitive log volume (e.g. INFO-level noise from third-party libraries slipping through, or high-QPS services). Instead of only binary exclude/include, this applies **random sampling**:
- 90% of INFO logs dropped
- 95% of DEBUG logs dropped

**Why random sampling, not time-based sampling:**
- Random sampling gives a statistically even, unbiased view of log distribution across a time window — useful for spotting anomalies/error rates.
- Time-based sampling (e.g. "keep 1 log every N seconds") can miss bursts entirely or over-represent quiet periods, and is harder to reason about under variable traffic.
- Random sampling is stateless per-line — no need to track windows/counters in the agent, which keeps Fluent Bit lightweight.

**Impact on Loki:** Further reduces cardinality/volume without fully blinding you to a log category — you retain a representative sample for debugging trends, instead of zero visibility.

## 3. Why This Cannot Be Done Server-Side (Loki)

**Loki has no log volume reduction capability at ingestion time.** Sampling, filtering, and exclusion must happen at the **agent/client (Fluent Bit)** before logs are shipped. Once a log line reaches Loki, it is stored as-is (subject to Loki's own dedup rules below) — Loki does not sample, drop, or reduce volume server-side.

**Loki's only built-in reduction:** Loki deduplicates log lines when the **timestamp** and **log level/content stream** are identical (exact duplicate lines within the same stream). This is not a volume-control feature — it's just duplicate suppression, not sampling.

## 4. Pattern Ingester — Disabled

```yaml
pattern_ingester:
  enabled: false
patternIngester:
  enabled: false
```

**Why disabled:** Pattern Ingester auto-detects repetitive log patterns for pattern-based analysis. It adds extra CPU/memory overhead on ingest and is not required here since volume is already controlled at the agent (grep + sampling). Enabling it would add cost without addressing our actual noise problem, which is solved upstream.

## 5. Loki Canary — Enabled

```yaml
lokiCanary:
  enabled: true
```

**Why:** Canary continuously writes and reads back known log lines to verify the Loki write/read path is healthy (no data loss, ingestion latency). This is our early-warning signal that the sampling/filtering pipeline hasn't broken ingestion — independent of real application traffic.

## 6. Chunks Cache — Enabled

```yaml
chunksCache:
  enabled: true
```

**Why:** With sampling reducing raw volume, remaining queries still hit historical chunks frequently (dashboards, alert rules). Caching chunks avoids repeated object-store (S3/MinIO) reads for the same data, reducing query latency and store load.

## 7. Tracing Enabled in Loki

```yaml
tracing:
  enabled: true
```

**Why:** With a multi-component distributed deployment (distributor → ingester → querier → query-frontend), tracing lets us follow a single query/write request across components to diagnose latency or failures. Without it, debugging cross-component slowness in a distributed Loki is guesswork.

## 8. Why Not Aggregate Logs (Do It at Visualization Layer Instead)

Aggregating/rolling up logs server-side is intentionally avoided. Aggregation should happen at the **visualization/query layer** (Grafana dashboards, LogQL aggregations), not by transforming/collapsing logs before storage.

**Drawbacks of pre-storage aggregation:**
- **Timestamp loss** — aggregated entries can't represent the original per-event time, breaking time-series correlation.
- **Original log loss** — once aggregated, the raw/original log line is gone; you can't drill back down for root-cause debugging.
- **Increased memory usage** — aggregation requires buffering/state (counting, grouping) in the agent or pipeline, raising memory footprint versus simple stateless filtering/sampling.

Keeping raw (sampled) logs intact in Loki and aggregating only at query time preserves the ability to drill into any individual event while still getting rollup views when needed.
