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

### 1.1 Additional Grep Filters — Drop by Namespace / Pod / Service / Regex

`grep` isn't limited to `log_level`. It can match/exclude on **any parsed key**, including Kubernetes metadata injected by the `kubernetes` filter (`$kubernetes['labels'][...]`, `$kubernetes['namespace_name']`, `$kubernetes['pod_name']`, etc.) and on **regex patterns**, not just exact strings.

**Example — drop logs from a specific app/namespace/pod:**

```
[FILTER]
    Name    grep
    Match   kube.*
    Exclude $kubernetes['labels']['app']         staging-load-test
    Exclude $kubernetes['namespace_name']        kube-system
    Exclude $kubernetes['pod_name']              ^loadgen-.*
    Exclude $kubernetes['labels']['app']         ^(healthcheck|metrics-exporter)$
```

- `Exclude $kubernetes['labels']['app'] staging-load-test` → drops all logs from the app labeled `staging-load-test` (e.g. a noisy load-test deployment we don't care about in prod logs).
- `Exclude $kubernetes['namespace_name'] kube-system` → drops all system-namespace noise (kubelet, CNI, etc.) if it isn't relevant to app-level observability.
- `Exclude $kubernetes['pod_name'] ^loadgen-.*` → **regex** match, drops any pod whose name starts with `loadgen-` (covers all replicas without listing each pod name).
- `Exclude $kubernetes['labels']['app'] ^(healthcheck|metrics-exporter)$` → regex alternation, drops multiple known-noisy services in one rule.

**Why this matters:** `grep` exclude rules aren't limited to log content/level — they can target **any label dimension** (namespace, pod, service/app name) and can use **regex** instead of exact match, so you can drop whole classes of known-noisy workloads (test/synthetic traffic, system namespaces, specific services) without touching application code or waiting on a log-level fix.

### 1.2 Regex on Log Content Itself — Drop a Specific Log Line/Pattern

Same as the existing `Exclude log /api/v1/health` rule — `grep` regex can also match directly on the **log message text**, not just labels. This is useful when a specific noisy line/endpoint keeps showing up in logs and needs to be dropped, regardless of which pod/namespace it comes from.

```
[FILTER]
    Name    grep
    Match   kube.*
    Exclude log    /api/v1/logs
```

- This rule drops any log line where the string/pattern `/api/v1/logs` appears — regardless of which pod or namespace it came from.
- Regex works too, e.g. `Exclude log /api/v1/(logs|health|metrics).*` — a single rule can cover multiple noisy endpoints at once.
- The match isn't limited to a plain substring — it's a full regex engine, so you can also match partial URLs with query params, or something like a specific status code, e.g. `Exclude log status=200.*GET /ping`.

**Note:** matching on the `log` field only works when `Merge_Log On` is set (same requirement as Section 1) — otherwise the regex won't reliably match against the raw JSON blob.

### 1.3 Option — As Actually Implemented (`values.yaml`)

The live `values.yaml` config takes a slightly different shape than 1.0–1.2 above:

```
[FILTER]
    Name    grep
    Match   kube.*
    Exclude log ^DEBUG
    Exclude log /api/v1/readyz
```

**What's different here:**
- Instead of `Exclude log_level DEBUG` (matching a parsed field), it matches `^DEBUG` directly against the raw `log` text, anchored at the start of the line. This only works if your app actually prefixes debug lines with the literal string `DEBUG` (e.g. `DEBUG: cache miss...`) — same caveat as the Lua script discussion below.
- INFO isn't excluded at grep level at all in this version — INFO filtering is left entirely to the Lua sampling filter (Section 2.1) instead of being fully dropped here. That's a valid design choice: grep does a hard cut on DEBUG (rarely useful, safe to fully drop), while INFO is only *thinned out* probabilistically so you keep a representative sample rather than losing INFO-level visibility completely.
- The health-check endpoint excluded is `/api/v1/readyz` rather than `/api/v1/health` — worth double-checking against your actual probe path (Kubernetes readiness probes commonly hit `/readyz`, `/healthz`, or `/api/v1/health` depending on the app/framework — pick whichever matches what's actually configured on your Deployments' `readinessProbe`).

**Why you might prefer this version:** it's a leaner ruleset (2 lines vs 3), and it deliberately splits responsibility — grep for a hard binary exclude (DEBUG, readiness noise), Lua for probabilistic thinning (INFO). The tradeoff is it depends on raw-text prefix matching rather than `Merge_Log On` + parsed `log_level`, so it's more fragile to log-format changes (see 2.1 below).

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

**Actual script (`sampling.lua`):**

```lua
function sample_info(tag, timestamp, record)
  local level = record["log_level"]
  if not level then
    return 0, 0, 0
  end
  if level == "INFO" then
    if math.random() < 0.9 then
      return -1, 0, 0
    end
  elseif level == "DEBUG" then
    if math.random() < 0.95 then
      return -1, 0, 0
    end
  end
  return 0, 0, 0
end
```

**Logic:**
- No `log_level` field → record passed through unchanged (`return 0,0,0`). This is why `Merge_Log On` matters here too — without it, `record["log_level"]` is nil and sampling never triggers.
- `log_level == "INFO"` → 90% chance of drop (`return -1,0,0` = drop record).
- `log_level == "DEBUG"` → 95% chance of drop.
- Any other level (WARN, ERROR, etc.) → always kept, unaffected by sampling.

This runs *after* the grep filter as a second layer — grep already excludes INFO/DEBUG entirely in this config, so in practice this Lua filter acts as a safety net for any INFO/DEBUG lines that bypass grep (e.g. mismatched label casing) or is ready to take over sampling duty if the exclude rules are relaxed later.

### 2.1 Option — As Actually Implemented (`values.yaml`)

The live script takes a different approach — it doesn't rely on a parsed `log_level` field at all:

```lua
function sample_info(tag, timestamp, record)
  local msg = record["log"]
  if not msg then
    return 0, timestamp, record
  end
  -- Sample INFO logs (drop ~50%)
  if string.match(msg, "^INFO:") then
    if math.random() < 0.5 then
      return -1, timestamp, record
    end
  -- Sample DEBUG logs (drop ~95%)
  elseif string.match(msg, "^DEBUG:") then
    if math.random() < 0.95 then
      return -1, timestamp, record
    end
  end
  return 0, timestamp, record
end
```

**What's different here, and why it matters:**
- **Matches on raw text, not a parsed field.** It reads `record["log"]` and does `string.match(msg, "^INFO:")` / `"^DEBUG:"` — a prefix match on the literal log line — instead of checking `record["log_level"]`. This means it does **not** depend on `Merge_Log On` or on the `kubernetes` filter having parsed a `log_level` key. It'll run even if that parsing never happens.
- **Trade-off:** because it's a raw prefix match, it only works if the app's log lines literally start with `INFO:` / `DEBUG:` (case-sensitive, anchored at the very start). It will silently fail to match (and therefore never sample) if logs are JSON-structured (`{"level":"info",...}`), lowercase (`info:`), or timestamp-prefixed (`2026-07-20T10:00:00 INFO: ...`). Worth checking a handful of real pod logs to confirm the format actually matches before relying on this.
- **Different drop rates:** 50% for INFO (vs 90% in the field-based version) and 95% for DEBUG (same as before). The lower INFO drop rate keeps more INFO-level visibility — makes sense as a complement to 1.3, where grep isn't excluding INFO at all anymore, so Lua is the *only* thing thinning INFO volume and a softer 50% avoids over-trimming.
- **Return signature uses `timestamp, record`** instead of `0, 0`. Both are valid Lua filter return conventions (`code, timestamp, record`) — using the real `timestamp`/`record` on pass-through is slightly safer/more explicit than hardcoding zeros, since it guarantees the original values are preserved unchanged rather than relying on Fluent Bit's handling of `0`.

**Why you might prefer this version:** it's decoupled from `Merge_Log On` and Kubernetes-filter parsing, so it's robust even if that pipeline stage misbehaves. The cost is it's now coupled to your application's raw log-line format instead — so it's really a choice between "depend on Fluent Bit's kubernetes-filter parsing" vs "depend on your app's log prefix convention" as the single point of failure. Pick whichever is more stable/less likely to silently drift in your environment.

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

### 4.1 Option — As Actually Implemented (`values.yaml`)

The live config actually has both **enabled**, not disabled:

```yaml
loki:
  structuredConfig:
    pattern_ingester:
      enabled: true

patternIngester:
  enabled: true
  replicas: 1
```

**Why you might want it enabled instead:** Pattern Ingester auto-detects repeated log patterns and clusters them, which powers Grafana's "Explore > Patterns" view — useful for eyeballing what your dominant log shapes are and spotting a new/unusual pattern spiking, without writing LogQL by hand. If you're leaning on agent-side sampling but still want quick pattern-level visibility into what's flowing through (e.g. to sanity-check that sampling isn't hiding a new error pattern), keeping it on is reasonable — it's a query/analysis convenience feature, separate from volume control.

**Trade-off to flag:** this is a direct contradiction of the "why disabled" reasoning above — Pattern Ingester does add extra CPU/memory overhead per the docs. If it's enabled in your cluster right now, that's a deliberate cost you're paying for the pattern-clustering UI feature; worth explicitly deciding (and documenting) whether that's intentional or a leftover default, since the two versions of this doc now say opposite things.

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


## Refrence docs
https://docs.fluentbit.io/manual/data-pipeline/filters/grep#fluent-bit.conf
