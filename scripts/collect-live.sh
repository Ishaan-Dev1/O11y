#!/usr/bin/env bash
set -euo pipefail

NS="${1:?Usage: $0 <namespace> [kube-context]}"
CTX="${2:-}"
KUBECTL=(kubectl)
if [[ -n "$CTX" ]]; then
  KUBECTL+=(--context "$CTX")
fi
KUBECTL+=(--namespace "$NS")

OUT="otel-live-dump-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "==> Dumping live state for namespace '$NS'${CTX:+ (context: $CTX)} into $OUT/"

# 1. Workloads
"${KUBECTL[@]}" get deploy,sts,ds,po -o yaml > "$OUT/01-workloads.yaml" 2>&1
echo "   01-workloads.yaml"

# 2. ConfigMaps
"${KUBECTL[@]}" get cm -o yaml > "$OUT/02-configmaps.yaml" 2>&1
echo "   02-configmaps.yaml"

# 3. Network
"${KUBECTL[@]}" get svc,ep,ingress,networkpolicy -o yaml > "$OUT/03-network.yaml" 2>&1
echo "   03-network.yaml"

# 4. RBAC
"${KUBECTL[@]}" get sa,role,rolebinding,clusterrole,clusterrolebinding -o yaml > "$OUT/04-rbac.yaml" 2>&1
echo "   04-rbac.yaml"

# 5. Secrets
"${KUBECTL[@]}" get secrets -o yaml > "$OUT/05-secrets.yaml" 2>&1
echo "   05-secrets.yaml"

# 6. Scaling
"${KUBECTL[@]}" get hpa,pdb -o yaml > "$OUT/06-scaling.yaml" 2>&1
echo "   06-scaling.yaml"

# 7. Namespace & Context
"${KUBECTL[@]}" get ns "$NS" -o yaml > "$OUT/07-namespace.yaml" 2>&1
kubectl config current-context > "$OUT/context.txt" 2>&1
echo "   07-namespace.yaml, context.txt"

# 8. Extract Collector Config from ConfigMaps
for cm in otel-collector-config otelcol-config otel-config collector-config; do
  if "${KUBECTL[@]}" get cm "$cm" >/dev/null 2>&1; then
    for key in collector.yaml config.yaml otelcol.yaml otel-config.yaml; do
      if "${KUBECTL[@]}" get cm "$cm" -o jsonpath="{.data.$key}" > "$OUT/collector-config.yaml" 2>/dev/null && [[ -s "$OUT/collector-config.yaml" ]]; then
        echo "   collector-config.yaml (extracted from $cm:$key)"
        break 2
      fi
    done
  fi
done

# 9. OpenTelemetryCollector CR
if "${KUBECTL[@]}" get opentelemetrycollector -o yaml > "$OUT/08-otelcollector-cr.yaml" 2>&1; then
  echo "   08-otelcollector-cr.yaml"
fi

# 10. Instrumentation CRs
if "${KUBECTL[@]}" get instrumentation -o yaml > "$OUT/09-instrumentation-cr.yaml" 2>&1; then
  echo "   09-instrumentation-cr.yaml"
fi

# 11. Specific otel-collector deployment
"${KUBECTL[@]}" get deploy otel-collector-collector -o yaml > "$OUT/10-otel-collector-deploy.yaml" 2>&1 || true
echo "   10-otel-collector-deploy.yaml"

echo
echo "Done. Archive $OUT/ and share with me for values.yaml generation."
