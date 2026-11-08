#!/bin/bash
# ==============================================================================
# Resource adoption script for victoria-metrics-k8s-stack on the monitoring
# namespace.
#
# Purpose: the Helm release was deleted (helm uninstall) but all Kubernetes
# resources were left behind. Resources are missing Helm's OWNERSHIP
# ANNOTATIONS (meta.helm.sh/release-name, meta.helm.sh/release-namespace),
# which Helm requires before it will manage an existing resource under a new
# release.
#
# This script patches ONLY annotations/labels — it does NOT delete, restart,
# or modify the spec of any resource. Safe to run against live resources.
#
# Run this BEFORE `helm upgrade --install`:
#   helm upgrade --install vm . -n monitoring -f values.yaml
#
# Resource names verified from live cluster:
#   Deployments : vmagent-vm, vmalert-vm, vminsert-vm,
#                 vm-kube-state-metrics, vm-victoria-metrics-operator
#   StatefulSets: vm-grafana, vmalertmanager-vm, vmselect-vm, vmstorage-vm
#   DaemonSet   : vm-prometheus-node-exporter
# ==============================================================================

set -euo pipefail

NS="monitoring"
RELEASE="vm"

# ---------------------------------------------------------------------------
# adopt_ns  — namespace-scoped resource
# adopt_cls — cluster-scoped resource
# ---------------------------------------------------------------------------
adopt_ns() {
  local resource="$1"
  echo "Adopting [ns] ${resource}"
  kubectl annotate "${resource}" -n "${NS}" \
    "meta.helm.sh/release-name=${RELEASE}" \
    "meta.helm.sh/release-namespace=${NS}" \
    --overwrite 2>/dev/null || { echo "  (skip: ${resource} not found)"; return; }
  kubectl patch "${resource}" -n "${NS}" --type=merge \
    -p '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"Helm"}}}' \
    2>/dev/null && echo "  labeled OK" || echo "  (label patch failed: ${resource})"
}

adopt_cls() {
  local resource="$1"
  echo "Adopting [cls] ${resource}"
  kubectl annotate "${resource}" \
    "meta.helm.sh/release-name=${RELEASE}" \
    "meta.helm.sh/release-namespace=${NS}" \
    --overwrite 2>/dev/null || { echo "  (skip: ${resource} not found)"; return; }
  kubectl patch "${resource}" --type=merge \
    -p '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"Helm"}}}' \
    2>/dev/null && echo "  labeled OK" || echo "  (label patch failed: ${resource})"
}

echo "=== Adopting resources for release: ${RELEASE} (ns: ${NS}) ==="

# ─────────────────────────────────────────────────────────────────────────────
# victoria-metrics-operator
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- victoria-metrics-operator ---"
adopt_ns  "deploy/vm-victoria-metrics-operator"
adopt_ns  "sa/vm-victoria-metrics-operator"
adopt_ns  "svc/vm-victoria-metrics-operator"
adopt_ns  "svc/vm-victoria-metrics-operator-webhook"
adopt_ns  "secret/vm-victoria-metrics-operator-validation-webhook-certs"
adopt_cls "clusterrole/vm-victoria-metrics-operator"
adopt_cls "clusterrolebinding/vm-victoria-metrics-operator"
adopt_cls "mutatingwebhookconfiguration/vm-victoria-metrics-operator-admission"
adopt_cls "validatingwebhookconfiguration/vm-victoria-metrics-operator-admission"

# CRDs
for crd in \
  vmagents.operator.victoriametrics.com \
  vmalerts.operator.victoriametrics.com \
  vmalertmanagers.operator.victoriametrics.com \
  vmalertmanagerconfigs.operator.victoriametrics.com \
  vmauths.operator.victoriametrics.com \
  vmclusters.operator.victoriametrics.com \
  vmnodescrapes.operator.victoriametrics.com \
  vmpodscrapes.operator.victoriametrics.com \
  vmprobes.operator.victoriametrics.com \
  vmrules.operator.victoriametrics.com \
  vmservicescrapes.operator.victoriametrics.com \
  vmsingles.operator.victoriametrics.com \
  vmstaticscrapes.operator.victoriametrics.com \
  vmusers.operator.victoriametrics.com \
  vmlogs.operator.victoriametrics.com; do
  adopt_cls "crd/${crd}"
done

# ─────────────────────────────────────────────────────────────────────────────
# VMCluster (CR + operator-created StatefulSets/Services)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- VMCluster ---"
adopt_ns "vmcluster/vm"

adopt_ns "sts/vmstorage-vm"
adopt_ns "svc/vmstorage-vm"

adopt_ns "sts/vmselect-vm"
adopt_ns "svc/vmselect-vm"

adopt_ns "deploy/vminsert-vm"
adopt_ns "svc/vminsert-vm"

# ─────────────────────────────────────────────────────────────────────────────
# VMAgent
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- VMAgent ---"
adopt_ns "vmagent/vm"
adopt_ns "deploy/vmagent-vm"
adopt_ns "svc/vmagent-vm"
adopt_ns "sa/vmagent-vm"
adopt_cls "clusterrole/vmagent-vm"
adopt_cls "clusterrolebinding/vmagent-vm"

# ─────────────────────────────────────────────────────────────────────────────
# VMAlert
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- VMAlert ---"
adopt_ns "vmalert/vm"
adopt_ns "deploy/vmalert-vm"
adopt_ns "svc/vmalert-vm"
adopt_ns "sa/vmalert-vm"
adopt_cls "clusterrole/vmalert-vm"
adopt_cls "clusterrolebinding/vmalert-vm"

# ─────────────────────────────────────────────────────────────────────────────
# VMAlertmanager
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- VMAlertmanager ---"
adopt_ns "vmalertmanager/vm"
adopt_ns "sts/vmalertmanager-vm"
adopt_ns "svc/vmalertmanager-vm"
adopt_ns "sa/vmalertmanager-vm"

# ─────────────────────────────────────────────────────────────────────────────
# Grafana (StatefulSet — persistence.type=sts)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Grafana ---"
adopt_ns "sts/vm-grafana"
adopt_ns "svc/vm-grafana"
adopt_ns "sa/vm-grafana"
adopt_ns "ingress/vm-grafana"
adopt_ns "secret/vm-grafana"
adopt_ns "configmap/vm-grafana"
adopt_ns "configmap/vm-grafana-datasources"
adopt_cls "clusterrole/vm-grafana-clusterrole"
adopt_cls "clusterrolebinding/vm-grafana-clusterrolebinding"

# ─────────────────────────────────────────────────────────────────────────────
# Prometheus Node Exporter (DaemonSet)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Prometheus Node Exporter ---"
adopt_ns "ds/vm-prometheus-node-exporter"
adopt_ns "svc/vm-prometheus-node-exporter"
adopt_ns "sa/vm-prometheus-node-exporter"
adopt_cls "clusterrole/vm-prometheus-node-exporter"
adopt_cls "clusterrolebinding/vm-prometheus-node-exporter"

# ─────────────────────────────────────────────────────────────────────────────
# Kube State Metrics
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Kube State Metrics ---"
adopt_ns "deploy/vm-kube-state-metrics"
adopt_ns "svc/vm-kube-state-metrics"
adopt_ns "sa/vm-kube-state-metrics"
adopt_cls "clusterrole/vm-kube-state-metrics"
adopt_cls "clusterrolebinding/vm-kube-state-metrics"

# ─────────────────────────────────────────────────────────────────────────────
# VMServiceScrapes
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- VMServiceScrapes ---"
for vss in \
  vm-kube-state-metrics \
  vm-node-exporter \
  vm-grafana \
  vm-alertmanager \
  vm-operator; do
  adopt_ns "vmservicescrape/${vss}"
done

# ─────────────────────────────────────────────────────────────────────────────
# Default Dashboard ConfigMaps
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Default Dashboard ConfigMaps ---"
for cm in \
  vm-k8s-system-api-server \
  vm-k8s-coredns \
  vm-k8s-system-scheduler \
  vm-k8s-views-nodes \
  vm-k8s-views-pods \
  vm-victoria-metrics-operator; do
  adopt_ns "configmap/${cm}"
done

echo ""
echo "=== Adoption complete ==="
echo ""
echo "Verify a resource:"
echo "  kubectl get deploy vm-victoria-metrics-operator -n ${NS} -o jsonpath='{.metadata.annotations}' | jq ."
echo ""
echo "Then re-install:"
echo "  helm upgrade --install ${RELEASE} <chart-path> -n ${NS} -f values.yaml"
