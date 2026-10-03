#!/usr/bin/env bash
set -euo pipefail

NS="${1:?Usage: $0 <namespace> [kube-context]}"
CTX="${2:-}"
KUBECTL=(kubectl)
if [[ -n "$CTX" ]]; then
  KUBECTL+=(--context "$CTX")
fi
KUBECTL+=(--namespace "$NS")

OUT="ldc-live-dump-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "==> Dumping live state for namespace '$NS'${CTX:+ (context: $CTX)} into $OUT/"

"${KUBECTL[@]}" get cm -o yaml > "$OUT/01-configmaps.yaml" 2>&1
echo "   01-configmaps.yaml"

"${KUBECTL[@]}" get deploy,sts,rs,po -o yaml > "$OUT/02-workloads.yaml" 2>&1
echo "   02-workloads.yaml"

"${KUBECTL[@]}" get hpa,svc,pvc,ep -o yaml > "$OUT/03-scaling-network-storage.yaml" 2>&1
echo "   03-scaling-network-storage.yaml"

"${KUBECTL[@]}" get secrets -o yaml > "$OUT/04-secrets.yaml" 2>&1
echo "   04-secrets.yaml"

"${KUBECTL[@]}" get ingress,httproute,gateway,networkpolicy -o yaml > "$OUT/05-routes.yaml" 2>&1
echo "   05-routes.yaml"

"${KUBECTL[@]}" get sa,serviceaccount,role,rolebinding -o yaml > "$OUT/06-rbac-sa.yaml" 2>&1
echo "   06-rbac-sa.yaml"

"${KUBECTL[@]}" get ns "$NS" -o yaml > "$OUT/07-namespace.yaml" 2>&1
echo "   07-namespace.yaml"

kubectl config current-context > "$OUT/context.txt" 2>&1
echo "   context.txt"

# Pull the rendered tempo.yaml / overrides.yaml straight out of the configmap
if "${KUBECTL[@]}" get cm tempo-config -o jsonpath='{.data.tempo\.yaml}' > "$OUT/tempo.yaml" 2>/dev/null; then
  echo "   tempo.yaml (extracted from tempo-config)"
fi
if "${KUBECTL[@]}" get cm tempo-config -o jsonpath='{.data.overrides\.yaml}' > "$OUT/overrides.yaml" 2>/dev/null; then
  echo "   overrides.yaml (extracted from tempo-config)"
fi
if ! "${KUBECTL[@]}" get cm tempo-config >/dev/null 2>&1; then
  echo "   (no cm named 'tempo-config' found - check 01-configmaps.yaml for the real name)"
fi

echo
echo "Done. Pass the folder's files to me for parity diff vs POC chart."
