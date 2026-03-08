#!/usr/bin/env bash
# Pulls all images required by the cluster and loads them into the kind node.
# Run this once on a good connection. After that, recreating the cluster
# only needs `kind load` (no internet required).
#
# Usage:
#   ./scripts/preload-images.sh          # pull + load
#   ./scripts/preload-images.sh --load-only  # skip pull, just load into kind

set -euo pipefail

IMAGES=(
  # PostgreSQL cluster
  "ghcr.io/cloudnative-pg/postgresql:18"

  # CloudNativePG operator
  "ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1"

  # PGBouncer (managed by the operator)
  "ghcr.io/cloudnative-pg/pgbouncer:1.25.1"

  # Barman Cloud Plugin + sidecar injected into each PostgreSQL pod
  "ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.11.0"
  "ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.11.0"

  # cert-manager (required by Barman Cloud Plugin)
  "quay.io/jetstack/cert-manager-controller:v1.17.1"
  "quay.io/jetstack/cert-manager-cainjector:v1.17.1"
  "quay.io/jetstack/cert-manager-webhook:v1.17.1"

  # nginx ingress controller
  "registry.k8s.io/ingress-nginx/controller:v1.14.3"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.7"

  # SeaweedFS components
  "chrislusf/seaweedfs:4.15"

  # Bucket creation job
  "curlimages/curl:8.18.0"
  "amazon/aws-cli:2.34.4"

  # PGAdmin
  "dpage/pgadmin4:9.13.0"

  # kube-prometheus-stack
  "quay.io/prometheus/prometheus:v3.10.0"
  "quay.io/prometheus-operator/prometheus-operator:v0.89.0"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.89.0"
  "ghcr.io/jkroepke/kube-webhook-certgen:1.7.8"
  "quay.io/prometheus/node-exporter:v1.10.2"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.18.0"
  "grafana/grafana:12.4.0"
  "quay.io/kiwigrid/k8s-sidecar:2.5.0"
)

LOAD_ONLY=false
if [[ "${1:-}" == "--load-only" ]]; then
  LOAD_ONLY=true
fi

echo "==> Checking kind cluster..."
CLUSTER_NAME=$(kind get clusters 2>/dev/null | head -1)
if [[ -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: No kind cluster found. Create one first with: kind create cluster --config kind-cluster.yaml"
  exit 1
fi
echo "    Using cluster: $CLUSTER_NAME"

if [[ "$LOAD_ONLY" == false ]]; then
  echo ""
  echo "==> Pulling images..."
  for image in "${IMAGES[@]}"; do
    echo "    Pulling $image"
    podman pull "$image"
  done
fi

echo ""
echo "==> Loading images into kind node..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

for image in "${IMAGES[@]}"; do
  echo "    Loading $image"
  TARFILE="$TMPDIR/$(echo "$image" | tr '/:@' '---').tar"
  podman save "$image" -o "$TARFILE"
  kind load image-archive "$TARFILE" --name "$CLUSTER_NAME"
  rm -f "$TARFILE"
done

echo ""
echo "Done. All images are cached in the kind node."
echo "Next time you recreate the cluster, run: ./scripts/preload-images.sh --load-only"
