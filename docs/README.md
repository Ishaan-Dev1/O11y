# Docs

Topic documentation that spans more than a single chart. Each chart also carries
its own README covering install, values, and verification.

| Component | Docs |
|---|---|
| Loki | [noise-reduction.md](loki/noise-reduction.md) · [storage-tiering.md](loki/storage-tiering.md) · [loki-canary.md](loki/loki-canary.md) · [backup-ldc.md](loki/backup-ldc.md) · [LDC-updated.md](loki/LDC-updated.md) |
| Tempo | [tempo3.0.md](tempo3.0.md) |
| GCP | [gcp-alb.md](gcp-alb.md) |
| Exporters | [postgres_exporter/metrics.md](postgres_exporter/metrics.md) |

`loki/LDC-updated.md` and `loki/backup-ldc.md` describe earlier POC versions of
the Loki chart and the LDC config comparison. They are kept for reference and may
be out of date relative to `charts/loki-standalone/`.

Images referenced by these docs live in [`../images/`](../images/).