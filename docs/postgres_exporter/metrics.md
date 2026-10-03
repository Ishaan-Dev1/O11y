# PostgreSQL Metrics for Grafana

This document lists all metrics exposed by `postgres-metrics-corrected.yaml` for Grafana dashboard creation.

## Overview

**44 metric groups** covering:
- Query performance & slow queries (with cardinality-safe design)
- Connection management
- Lock monitoring
- Table & index health
- Replication status
- Checkpoint & background writer
- Vacuum/Analyze progress
- Error & deadlock tracking
- WAL & storage metrics

---

## Slow Queries - Cardinality-Safe Design

**Problem:** Query text as Prometheus label causes cardinality explosion in VictoriaMetrics/Prometheus.

**Solution:** Two metrics with different scrape intervals:

| Metric Group | Scrape Interval | Purpose |
|--------------|-----------------|---------|
| `pg_slow_queries` | 15-60s (default) | Current slow queries with `queryid` (low cardinality) |
| `pg_slow_query_info` | 300s (5 min) | Query text lookup by `queryid` (rarely changes) |

---

## Metrics Catalog

### 1. Slow Queries (`pg_slow_queries`) — Frequent Scrape
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_slow_queries_query_duration_seconds` | GAUGE | pid, usename, datname, application_name, client_addr, state, **queryid**, wait_event_type, wait_event, backend_type | Current query execution time in seconds |
| `pg_slow_queries_session_duration_seconds` | GAUGE | pid, usename, datname, application_name, client_addr, state, **queryid**, wait_event_type, wait_event, backend_type | Session connection time in seconds |

**Grafana Queries:**
```promql
# Top 10 slowest queries (by queryid)
topk(10, pg_slow_queries_query_duration_seconds)

# Slow queries by database
sum by (datname) (pg_slow_queries_query_duration_seconds)

# Queries waiting on locks
pg_slow_queries_query_duration_seconds{wait_event_type="Lock"} > 5

# Count of slow queries (> 5s)
count(pg_slow_queries_query_duration_seconds > 5)
```

### 2. Slow Query Text Lookup (`pg_slow_query_info`) — Infrequent Scrape
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_slow_query_info` | GAUGE (always 1) | queryid, query | Normalized query text from pg_stat_statements |

**Usage:** Join in Grafana or recording rule:
```promql
# Recording rule (run every 5m)
pg_slow_query_text: pg_slow_query_info * on (queryid) group_left(query) pg_slow_query_info

# Or in Grafana Table: Join pg_slow_queries (queryid) with pg_slow_query_info (queryid -> query)
```

---

### 2. Waiting Queries (`pg_waiting_queries`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_waiting_queries_waiting_queries` | GAUGE | (none) | Number of active queries waiting for resources |

---

### 3. Running Queries (`pg_running_queries`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_running_queries_running_queries` | GAUGE | (none) | Number of currently active queries |

---

### 4. Concurrent Queries (`pg_concurrent_queries`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_concurrent_queries_concurrent_queries` | GAUGE | (none) | Total concurrent connections excluding collector |

---

### 5. Query Connections by Database (`pg_query_connections`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_query_connections_total_connections` | GAUGE | datname | Total connections per database |

---

### 6. Blocked Queries (`pg_blocked_queries`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_blocked_queries_blocked_queries` | GAUGE | (none) | Number of queries blocked waiting for locks |

---

### 7. Idle Transactions (`pg_idle_transactions`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_idle_transactions_idle_transactions` | GAUGE | (none) | Number of idle in transaction connections |

---

### 8. Longest Lock Wait (`pg_longest_lock_wait`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_longest_lock_wait_longest_lock_wait_seconds` | GAUGE | (none) | Longest time a query has been waiting for a lock |

---

### 9. Table Bloat (`pg_table_bloat`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_table_bloat_n_dead_tup` | GAUGE | schemaname, tablename | Dead tuples needing vacuum |
| `pg_table_bloat_n_live_tup` | GAUGE | schemaname, tablename | Live tuples in table |

**Grafana:**
```promql
# Tables with most bloat
topk(10, pg_table_bloat_n_dead_tup / pg_table_bloat_n_live_tup * 100)
```

---

### 10. Unused Indexes (`pg_unused_indexes`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_unused_indexes_idx_scan` | COUNTER | schemaname, index_name | Index scan count (0 = unused) |

**Grafana:**
```promql
# Unused indexes (never scanned)
pg_unused_indexes_idx_scan == 0
```

---

### 11. Missing Indexes (`pg_missing_indexes`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_missing_indexes_seq_scan` | COUNTER | schemaname, table_name | Sequential scan count |
| `pg_missing_indexes_idx_scan` | COUNTER | schemaname, table_name | Index scan count |

**Grafana:**
```promql
# Tables needing indexes (high seq scan vs index scan ratio)
pg_missing_indexes_seq_scan / nullif(pg_missing_indexes_idx_scan, 0) > 10
```

---

### 12. Connection States (`pg_connection_states`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_connection_states_connections` | GAUGE | datname, state | Connections per database and state |

**Grafana:**
```promql
# Active connections by database
pg_connection_states_connections{state="active"}

# Idle in transaction by database
pg_connection_states_connections{state="idle in transaction"}
```

---

### 13. User/DB/State Connections (`pg_user_db_connections_by_state`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_user_db_connections_by_state_connections` | GAUGE | datname, usename, state | Connections per database, user, and state |

---

### 14. Top Queries by CPU (`pg_top_queries_by_cpu`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_top_queries_by_cpu_calls` | COUNTER | queryid | Total executions |
| `pg_top_queries_by_cpu_total_exec_time` | GAUGE | queryid | Total execution time (ms) |
| `pg_top_queries_by_cpu_mean_exec_time` | GAUGE | queryid | Mean execution time (ms) |

**Note:** Uses `queryid` only (no query text label) for cardinality safety. Join with `pg_slow_query_info` or `pg_stat_statements` for query text.

**Grafana:**
```promql
# Top CPU consumers
topk(10, pg_top_queries_by_cpu_total_exec_time)

# Queries with highest avg time
topk(10, pg_top_queries_by_cpu_mean_exec_time)

# Call rate
rate(pg_top_queries_by_cpu_calls[5m])
```

---

### 15. Top Queries by Memory (`pg_top_queries_by_memory`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_top_queries_by_memory_shared_blks_hit` | COUNTER | queryid | Shared buffer hits |
| `pg_top_queries_by_memory_shared_blks_read` | COUNTER | queryid | Shared buffer reads (disk IO) |

**Note:** Uses `queryid` only (no query text label) for cardinality safety.

**Grafana:**
```promql
# Cache hit ratio per query
pg_top_queries_by_memory_shared_blks_hit / (pg_top_queries_by_memory_shared_blks_hit + pg_top_queries_by_memory_shared_blks_read) * 100
```

---

### 16. Top Queries by IOPS (`pg_top_queries_by_iops`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_top_queries_by_iops_total_io` | COUNTER | queryid | Total block reads (shared + local + temp) |

**Note:** Uses `queryid` only (no query text label) for cardinality safety.

---

### 17. Database Size (`pg_database_size_bytes`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_database_size_bytes_size_bytes` | GAUGE | datname | Database size in bytes |

**Grafana:**
```promql
# DB size in GB
pg_database_size_bytes_size_bytes / 1024 / 1024 / 1024

# Growth rate
rate(pg_database_size_bytes_size_bytes[1h]) * 3600 / 1024 / 1024 / 1024
```

---

### 18. Buffer Cache Hit Ratio (`pg_buffer_cache_hit_ratio`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_buffer_cache_hit_ratio_cache_hit_ratio` | GAUGE | datname | Buffer cache hit ratio % |

**Grafana:**
```promql
# Alert if < 95%
pg_buffer_cache_hit_ratio_cache_hit_ratio < 95
```

---

### 19. Uptime (`pg_uptime_days`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_uptime_days_uptime_days` | GAUGE | (none) | PostgreSQL uptime in days |

---

### 20. Table Locks (`pg_table_locks`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_table_locks_lock_count` | GAUGE | table_name, mode | Lock count per table and mode |

**Grafana:**
```promql
# Exclusive locks
pg_table_locks_lock_count{mode=~"Exclusive|AccessExclusive"}
```

---

### 21. Row Locks (`pg_row_locks`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_row_locks_row_lock_count` | GAUGE | mode, usename | Row-level lock count per mode and user |

---

### 22. WAL Receiver (`pg_wal_receiver`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_wal_receiver_wal_receiver_up` | GAUGE | sender_host, slot_name | WAL receiver status (1=streaming) |

---

### 23. Checkpoint (`pg_checkpoint`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_checkpoint_checkpoints_timed` | COUNTER | (none) | Scheduled checkpoints |
| `pg_checkpoint_checkpoints_req` | COUNTER | (none) | Requested checkpoints |
| `pg_checkpoint_checkpoint_write_time` | GAUGE | (none) | Checkpoint write time (ms) |
| `pg_checkpoint_checkpoint_sync_time` | GAUGE | (none) | Checkpoint sync time (ms) |

**Grafana:**
```promql
# Checkpoint frequency
rate(pg_checkpoint_checkpoints_timed[5m]) + rate(pg_checkpoint_checkpoints_req[5m])

# Checkpoint duration
pg_checkpoint_checkpoint_write_time + pg_checkpoint_checkpoint_sync_time
```

---

### 24. Replication Count (`pg_replication_count`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_replication_count_replica_count` | GAUGE | (none) | Number of streaming replicas |

---

### 25. Replication Status (`pg_replication_status`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_replication_status_streaming` | GAUGE | application_name, state, sync_state | Replica streaming status |

---

### 26. Replication Slots (`pg_replication_slot`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_replication_slot_active` | GAUGE | slot_name | Slot active status (1=active) |

**Grafana:**
```promql
# Inactive slots (risk of WAL bloat)
pg_replication_slot_active == 0
```

---

### 27. Archiver (`pg_archiver`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_archiver_archived_count` | COUNTER | (none) | WAL files archived successfully |
| `pg_archiver_failed_count` | COUNTER | (none) | WAL archive failures |
| `pg_archiver_last_archive_age` | GAUGE | (none) | Seconds since last archive |

**Grafana:**
```promql
# Archive lag alert
pg_archiver_last_archive_age > 300

# Archive failure rate
rate(pg_archiver_failed_count[5m])
```

---

### 28. Recovery Status (`pg_recovery`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_recovery_in_recovery` | GAUGE | (none) | 1=standby, 0=primary |

---

### 29. Freeze Age (`pg_freeze_age`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_freeze_age_freeze_age` | GAUGE | datname | Transaction ID age before wraparound vacuum |

**Grafana:**
```promql
# Alert near wraparound (2B = 2 billion)
pg_freeze_age_freeze_age > 1500000000
```

---

### 30. Autovacuum Workers (`pg_autovacuum`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_autovacuum_autovacuum_workers` | GAUGE | (none) | Active autovacuum workers |

---

### 31. Vacuum Progress (`pg_vacuum_progress`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_vacuum_progress_vacuum_running` | GAUGE | (none) | Vacuum operations in progress |

---

### 32. Analyze Progress (`pg_analyze_progress`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_analyze_progress_analyze_running` | GAUGE | (none) | Analyze operations in progress |

---

### 33. Deadlocks (`pg_deadlocks`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_deadlocks_deadlocks` | COUNTER | datname | Total deadlocks per database |

**Grafana:**
```promql
# Deadlock rate
rate(pg_deadlocks_deadlocks[5m])
```

---

### 34. Recovery Conflicts (`pg_recovery_conflicts`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_recovery_conflicts_conflicts` | COUNTER | datname | Recovery conflicts on standby |

---

### 35. Rollbacks (`pg_rollbacks`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_rollbacks_xact_rollback` | COUNTER | datname | Transaction rollbacks per database |

**Grafana:**
```promql
# Rollback rate
rate(pg_rollbacks_xact_rollback[5m])

# Rollback ratio
rate(pg_rollbacks_xact_rollback[5m]) / (rate(pg_rollbacks_xact_rollback[5m]) + rate(pg_stat_database_xact_commit[5m]))
```

---

### 36. Temp Files (`pg_temp_files`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_temp_files_temp_files` | COUNTER | datname | Temporary files created |
| `pg_temp_files_temp_bytes` | COUNTER | datname | Temporary bytes written |

**Grafana:**
```promql
# Temp file rate (spilling to disk)
rate(pg_temp_files_temp_files[5m])

# Temp bytes rate
rate(pg_temp_files_temp_bytes[5m]) / 1024 / 1024
```

---

### 37. WAL Bytes (`pg_wal_bytes`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_wal_bytes_wal_bytes` | COUNTER | (none) | Total WAL bytes since cluster init |

**Grafana:**
```promql
# WAL generation rate (MB/s)
rate(pg_wal_bytes_wal_bytes[1m]) / 1024 / 1024
```

---

### 38. WAL Size / Replication Lag (`pg_wal_size`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_wal_size_replication_lag_bytes` | GAUGE | application_name | Replication lag in bytes per replica |

**Grafana:**
```promql
# Replication lag in MB
pg_wal_size_replication_lag_bytes / 1024 / 1024

# Alert if lag > 100MB
pg_wal_size_replication_lag_bytes > 100000000
```

---

### 39. BGWriter Buffers (`pg_bgwriter_buffers`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_bgwriter_buffers_buffers_checkpoint` | COUNTER | (none) | Buffers written by checkpoints |
| `pg_bgwriter_buffers_buffers_backend` | COUNTER | (none) | Buffers written by backends |
| `pg_bgwriter_buffers_buffers_alloc` | COUNTER | (none) | Buffers allocated |

**Grafana:**
```promql
# Backend write ratio (high = checkpoint not keeping up)
rate(pg_bgwriter_buffers_buffers_backend[5m]) / rate(pg_bgwriter_buffers_buffers_alloc[5m]) * 100
```

---

### 40. Lock Waits (`pg_lock_waits`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_lock_waits_lock_wait_count` | GAUGE | table_name, mode | Lock wait count per table and mode |

---

### 41. Query Errors (`pg_query_errors`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_query_errors_deadlocks` | COUNTER | datname | Deadlock count |
| `pg_query_errors_temp_files` | COUNTER | datname | Temp file count |

---

### 42. Failed Queries (`pg_failed_queries`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_failed_queries_conflicts` | COUNTER | datname | Recovery conflicts |
| `pg_failed_queries_deadlocks` | COUNTER | datname | Deadlock count |

---

### 43. Blocking Details (`pg_blocking_details`)
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `pg_blocking_details_blocked_duration_seconds` | GAUGE | blocked_pid, blocked_user, blocked_db, blocked_query, blocked_wait_type, blocked_wait_event, blocking_pid, blocking_user, blocking_query | Blocked query wait time |
| `pg_blocking_details_blocking_duration_seconds` | GAUGE | blocked_pid, blocked_user, blocked_db, blocked_query, blocked_wait_type, blocked_wait_event, blocking_pid, blocking_user, blocking_query | Blocking query runtime |

**Grafana:**
```promql
# Longest blocking chains
topk(10, pg_blocking_details_blocked_duration_seconds)

# Blocking query details table
# Use "Table" panel with all label columns
```

---

## Recommended Grafana Dashboards

### 1. **Overview Dashboard**
- Connections (total, active, idle, idle in txn)
- Queries per second (commits, rollbacks, conflicts)
- Cache hit ratio
- WAL generation rate
- Replication lag

### 2. **Query Performance Dashboard**
- Top queries by CPU/IO/Memory
- Slow query table
- Query duration heatmap
- Cache hit ratio per query

### 3. **Lock Monitoring Dashboard**
- Blocked queries count
- Longest lock wait
- Lock wait details table (blocking chains)
- Lock modes distribution

### 4. **Storage & Maintenance Dashboard**
- Database sizes & growth
- Table bloat %
- Unused/missing indexes
- Temp file activity
- Freeze age (wraparound risk)

### 5. **Replication & HA Dashboard**
- Replica count & status
- Replication lag (bytes & time)
- WAL receiver status
- Archive status & lag
- Recovery conflicts

### 6. **Checkpoint & BGWriter Dashboard**
- Checkpoint frequency & duration
- Buffers written (checkpoint vs backend)
- Checkpoint sync time

---

## Prometheus Recording Rules (Optional)

```yaml
groups:
- name: postgres.rules
  rules:
  - expr: rate(pg_database_size_bytes_size_bytes[1h]) * 3600 / 1024 / 1024 / 1024
    record: postgres:database_size_growth_gb_per_hour
  - expr: pg_buffer_cache_hit_ratio_cache_hit_ratio
    record: postgres:buffer_cache_hit_ratio
  - expr: rate(pg_wal_bytes_wal_bytes[1m]) / 1024 / 1024
    record: postgres:wal_generation_mb_per_sec
  - expr: pg_wal_size_replication_lag_bytes / 1024 / 1024
    record: postgres:replication_lag_mb
```

---

## Required Permissions

```sql
-- For PostgreSQL 14+
GRANT pg_read_all_stats TO <collector_user>;

-- For PostgreSQL < 14
GRANT pg_monitor TO <collector_user>;

-- Required for pg_stat_statements queries
GRANT SELECT ON pg_stat_statements TO <collector_user>;
```

## postgresql.conf Settings

```conf
# For full query text in pg_stat_activity
track_activity_query_size = 4096  # default 1024, max 102400

# Required for query performance metrics
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
pg_stat_statements.max = 10000
```

---

## Version Compatibility

| Metric Group | Min PostgreSQL | Notes |
|--------------|----------------|-------|
| pg_stat_progress_vacuum | 9.6+ | |
| pg_stat_progress_analyze | 11+ | |
| pg_read_all_stats role | 14+ | Use pg_monitor for older |
| pg_stat_statements | 9.2+ (ext) | Extension required |
| pg_wal_lsn_diff | 10+ | |

---

## Files

- `postgres-metrics.yaml` - Main configuration (44 metric groups)
- This README.md - Metrics reference for Grafana

## Validation

Test queries against your PostgreSQL instance:

```bash
# Quick syntax check
python3 -c "import yaml; yaml.safe_load(open('postgres-metrics.yaml'))"

# Test individual queries (requires psql)
psql -d postgres -f <(python3 -c "
import yaml
data = yaml.safe_load(open('postgres-metrics.yaml'))
for name, cfg in data.items():
    print(f'-- {name}')
    print(cfg['query'])
    print()
")
```
