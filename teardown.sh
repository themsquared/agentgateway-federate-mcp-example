#!/usr/bin/env bash
#
# Tear the demo down.
#
#   ./teardown.sh              remove the demo namespace, leave agentgateway installed
#   ./teardown.sh --all        also uninstall agentgateway and the Gateway API CRDs
#   ./teardown.sh --cluster    delete the whole k3d cluster (fastest, most thorough)
#
# Everything the demo creates lives in one namespace, so the default is a single
# delete. The k3d cluster is only touched if you ask for it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "${SCRIPT_DIR}/.env" ] && { set -a; . "${SCRIPT_DIR}/.env"; set +a; }

CLUSTER_NAME="${CLUSTER_NAME:-mcp-federation}"
AGW_NS="${AGW_NS:-agentgateway-system}"
DEMO_NS="${DEMO_NS:-mcp-federation}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }

MODE="${1:-namespace}"

case "$MODE" in
  --cluster)
    info "Deleting k3d cluster '${CLUSTER_NAME}'..."
    k3d cluster delete "${CLUSTER_NAME}"
    ok "cluster deleted"
    ;;
  --all)
    info "Deleting demo namespace '${DEMO_NS}'..."
    kubectl delete namespace "${DEMO_NS}" --ignore-not-found --wait=true
    info "Uninstalling agentgateway..."
    helm uninstall enterprise-agentgateway -n "${AGW_NS}" 2>/dev/null || true
    helm uninstall enterprise-agentgateway-crds -n "${AGW_NS}" 2>/dev/null || true
    kubectl delete namespace "${AGW_NS}" --ignore-not-found --wait=false
    ok "demo and agentgateway removed"
    ;;
  namespace)
    info "Deleting demo namespace '${DEMO_NS}'..."
    kubectl delete namespace "${DEMO_NS}" --ignore-not-found --wait=true
    ok "demo removed (agentgateway left installed — re-run ./setup.sh --skip-install to rebuild)"
    ;;
  *)
    echo "usage: ./teardown.sh [--all|--cluster]"
    exit 1
    ;;
esac
