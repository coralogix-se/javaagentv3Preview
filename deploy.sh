#!/usr/bin/env bash
# Deploy the Java agent 2.32.0 database demo.
#
#   CX_PRIVATE_KEY=... ./deploy.sh legacy    # direct export, v3 preview off
#   CX_PRIVATE_KEY=... ./deploy.sh v3        # direct export, v3 preview on
#   CX_PRIVATE_KEY=... ./deploy.sh chart     # v3 preview only through otel-integration
#   CX_PRIVATE_KEY=... ./deploy.sh          # default: all three in one namespace
#   ./deploy.sh status
#   ./deploy.sh down
#
# Uses a kubeconfig under .kube/ so the default kubectl context is left alone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.kube/config}"
export CX_DOMAIN="${CX_DOMAIN:-us2.coralogix.com}"
export CX_CLUSTER_NAME="${CX_CLUSTER_NAME:-otel-java-v3}"
export CX_APP_NAME="${CX_APP_NAME:-otel-java-agent-3}"

KIND_CLUSTER="$CX_CLUSTER_NAME"
APP_NS="otel-java-v3"
CHART_NS="$APP_NS"
CHART_RELEASE="otel-coralogix-integration"
IMAGE="otel-java-orders:local"
# envsubst must not expand Kubernetes $(VAR) references in the manifests.
RENDER_VARS='${CX_DOMAIN} ${CX_CLUSTER_NAME} ${CX_APP_NAME} ${TRAFFIC_CALLS}'

usage() {
  cat <<EOF
Usage: CX_PRIVATE_KEY=... $0 [legacy|v3|chart|all|status|down]

  all      Default. legacy + v3 + chart in namespace otel-java-v3
  legacy   Agent 2.32.0, v3 preview off, OTLP direct to ingress.\${CX_DOMAIN}
  v3       Agent 2.32.0, v3 preview on, OTLP direct to ingress.\${CX_DOMAIN}
  chart    Agent 2.32.0, v3 preview on, OTLP only to the stock otel-integration agent
  status   Show pods
  down     Delete the kind cluster

Environment:
  CX_PRIVATE_KEY   Send-your-data API key. Required unless the namespace secret already exists.
  CX_DOMAIN        Coralogix domain (default: us2.coralogix.com)
  CX_CLUSTER_NAME  kind cluster name and chart global.clusterName (default: otel-java-v3)
  CX_APP_NAME      cx.application.name for the standalone apps (default: otel-java-agent-3)
  KUBECONFIG       Override the kubeconfig (default: $ROOT/.kube/config)
EOF
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

render() {
  envsubst "$RENDER_VARS" <"$1"
}

apply_rendered() {
  render "$1" | kubectl apply -f -
}

ensure_key() {
  local ns="$1"
  local name="$2"
  if [[ -n "${CX_PRIVATE_KEY:-}" ]]; then
    return 0
  fi
  if kubectl get namespace "$ns" >/dev/null 2>&1 && kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
    return 0
  fi
  echo "Set CX_PRIVATE_KEY to the send-your-data API key." >&2
  exit 1
}

write_secret() {
  local ns="$1"
  local name="$2"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  if [[ -z "${CX_PRIVATE_KEY:-}" ]]; then
    return 0
  fi
  local keyfile
  keyfile="$(mktemp)"
  chmod 600 "$keyfile"
  printf '%s' "$CX_PRIVATE_KEY" >"$keyfile"
  kubectl -n "$ns" create secret generic "$name" \
    --from-file=PRIVATE_KEY="$keyfile" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$keyfile"
}

ensure_cluster() {
  need kind
  need kubectl
  mkdir -p "$ROOT/.kube"
  if ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
    kind create cluster --name "$KIND_CLUSTER" --kubeconfig "$KUBECONFIG"
  fi
  kubectl config use-context "kind-$KIND_CLUSTER" >/dev/null
}

ensure_image() {
  need docker
  if [[ "${REBUILD:-}" == "1" ]] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    need mvn
    (cd "$ROOT/app" && mvn -q -DskipTests package && docker build -t "$IMAGE" .)
  fi
  kind load docker-image "$IMAGE" --name "$KIND_CLUSTER"
}

ensure_postgres() {
  apply_rendered "$ROOT/k8s/namespace.yaml"
  apply_rendered "$ROOT/k8s/postgres.yaml"
  kubectl -n "$APP_NS" rollout status deployment/postgres --timeout=180s
}

apply_traffic() {
  local services=("$@")
  local calls=""
  local service
  for service in "${services[@]}"; do
    calls+="                hit ${service}"$'\n'
  done
  TRAFFIC_CALLS="$calls" apply_rendered "$ROOT/k8s/traffic.yaml"
  kubectl -n "$APP_NS" rollout status deployment/traffic --timeout=180s
}

deploy_legacy() {
  ensure_key "$APP_NS" coralogix
  write_secret "$APP_NS" coralogix
  apply_rendered "$ROOT/k8s/orders-legacy.yaml"
  kubectl -n "$APP_NS" rollout status deployment/orders-legacy --timeout=180s
}

deploy_v3() {
  ensure_key "$APP_NS" coralogix
  write_secret "$APP_NS" coralogix
  apply_rendered "$ROOT/k8s/orders-v3.yaml"
  kubectl -n "$APP_NS" rollout status deployment/orders-v3 --timeout=180s
}

deploy_chart() {
  need helm
  ensure_key "$CHART_NS" coralogix-keys
  write_secret "$CHART_NS" coralogix-keys
  if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -qx coralogix-charts-virtual; then
    helm repo add coralogix-charts-virtual https://cgx.jfrog.io/artifactory/coralogix-charts-virtual
  fi
  helm upgrade --install "$CHART_RELEASE" coralogix-charts-virtual/otel-integration \
    --namespace "$CHART_NS" \
    --values <(render "$ROOT/k8s/otel-integration-values.yaml") \
    --timeout 10m
  kubectl -n "$CHART_NS" rollout status daemonset/coralogix-opentelemetry-agent --timeout=300s
  apply_rendered "$ROOT/k8s/orders-v3-chart.yaml"
  kubectl -n "$APP_NS" rollout status deployment/orders-v3-chart --timeout=180s
}

status() {
  echo "kubeconfig: $KUBECONFIG"
  echo "namespace: $APP_NS"
  kubectl -n "$APP_NS" get pods -o wide 2>/dev/null || true
}

down() {
  need kind
  kind delete cluster --name "$KIND_CLUSTER" --kubeconfig "$KUBECONFIG"
}

main() {
  local mode="${1:-all}"
  case "$mode" in
    -h|--help|help)
      usage
      exit 0
      ;;
    status)
      ensure_cluster
      status
      ;;
    down)
      down
      ;;
    legacy)
      ensure_cluster
      ensure_image
      ensure_postgres
      deploy_legacy
      apply_traffic orders-legacy
      status
      ;;
    v3)
      ensure_cluster
      ensure_image
      ensure_postgres
      deploy_v3
      apply_traffic orders-v3
      status
      ;;
    chart)
      ensure_cluster
      ensure_image
      ensure_postgres
      deploy_chart
      apply_traffic orders-v3-chart
      status
      ;;
    all)
      ensure_cluster
      ensure_image
      ensure_postgres
      deploy_legacy
      deploy_v3
      deploy_chart
      apply_traffic orders-legacy orders-v3 orders-v3-chart
      status
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
