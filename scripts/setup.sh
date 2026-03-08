#!/usr/bin/env bash
# Sets up the full postgres-k8s cluster from scratch.
# Run from the repo root: ./scripts/setup.sh
#
# Prerequisites: kubectl, helm, kind, podman

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { echo ""; echo "==> $*"; }
info() { echo "    $*"; }

wait_rollout() {
  local kind="$1" name="$2" ns="$3"
  info "Waiting for $kind/$name in $ns..."
  kubectl rollout status "$kind/$name" -n "$ns" --timeout=120s
}

# ── 0. cluster ────────────────────────────────────────────────────────────────

log "Creating kind cluster..."
if kind get clusters 2>/dev/null | grep -q .; then
  info "Kind cluster already exists, skipping."
else
  kind create cluster --config "$REPO_ROOT/kind-cluster.yaml"
fi

# ── 1. preload images ────────────────────────────────────────────────────────

log "Preloading images into kind..."
"$SCRIPT_DIR/preload-images.sh"

# ── 2. cert-manager ───────────────────────────────────────────────────────────

log "Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.1/cert-manager.yaml
wait_rollout deployment cert-manager cert-manager
wait_rollout deployment cert-manager-webhook cert-manager

# ── 3. CloudNativePG operator ─────────────────────────────────────────────────

log "Installing CloudNativePG operator..."
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.1.yaml
wait_rollout deployment cnpg-controller-manager cnpg-system

# ── 4. Barman Cloud Plugin ────────────────────────────────────────────────────

log "Installing Barman Cloud Plugin..."
kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.11.0/manifest.yaml
wait_rollout deployment barman-cloud cnpg-system

# ── 5. nginx ingress controller ───────────────────────────────────────────────

log "Installing nginx ingress controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
wait_rollout deployment ingress-nginx-controller ingress-nginx

# ── 6. kube-prometheus-stack ──────────────────────────────────────────────────

log "Installing kube-prometheus-stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

if helm list -n monitoring | grep -q kube-prometheus-stack; then
  info "kube-prometheus-stack already installed, upgrading..."
  helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --version 82.10.1 \
    --values "$REPO_ROOT/monitoring/values.yaml"
else
  helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --version 82.10.1 \
    --values "$REPO_ROOT/monitoring/values.yaml"
fi

wait_rollout deployment kube-prometheus-stack-grafana monitoring
wait_rollout deployment kube-prometheus-stack-kube-state-metrics monitoring

# ── 7. core manifests ─────────────────────────────────────────────────────────

log "Applying core manifests (kubectl apply -k)..."
kubectl apply -k "$REPO_ROOT"

# ── 8. wait for SeaweedFS ─────────────────────────────────────────────────────

log "Waiting for SeaweedFS..."
kubectl rollout status statefulset/seaweedfs-master -n data --timeout=120s
kubectl rollout status statefulset/seaweedfs-volume -n data --timeout=120s
kubectl rollout status statefulset/seaweedfs-filer  -n data --timeout=120s
kubectl rollout status deployment/seaweedfs-s3      -n data --timeout=120s

# ── 9. wait for bucket job ────────────────────────────────────────────────────

log "Waiting for bucket creation job..."
kubectl wait job/create-backup-bucket -n data --for=condition=complete --timeout=120s

# ── 10. wait for PostgreSQL cluster ────────────────────────────────────────────

log "Waiting for PostgreSQL cluster to be healthy..."
for i in $(seq 1 60); do
  STATUS=$(kubectl get cluster postgres-cluster -n data -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$STATUS" == "Cluster in healthy state" ]]; then
    info "Cluster is healthy."
    break
  fi
  info "($i/60) status: ${STATUS:-pending}..."
  sleep 10
done

# ── 11. done ─────────────────────────────────────────────────────────────────

log "Done!"
echo ""
echo "  Open:"
echo "    http://pgadmin.localhost:8080    — PGAdmin  (admin@example.com / pgadmin123)"
echo "    http://grafana.localhost:8080    — Grafana  (admin / grafanaadmin123)"
echo "    http://seaweedfs.localhost:8080  — SeaweedFS filer UI"
echo ""
