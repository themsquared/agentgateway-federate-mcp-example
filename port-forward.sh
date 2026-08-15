#!/usr/bin/env bash
#
# Open the three port-forwards the demo scripts expect, and hold them open.
#
#   localhost:8080  → the federated MCP gateway   (what a customer's agent calls)
#   localhost:8081  → Keycloak                    (all three company realms)
#   localhost:9090  → Prometheus                  (chargeback data)
#
# Run this in its own terminal and leave it running. Ctrl-C stops all three.
#
# Note on Keycloak: tokens minted through this port-forward carry the in-cluster
# issuer, not localhost, because KC_HOSTNAME is pinned in the deployment. That is
# what lets a token you fetched from your laptop be accepted by the gateway.

set -euo pipefail

NS="${DEMO_NS:-mcp-federation}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

PIDS=()
cleanup() {
  echo ""
  echo -e "${DIM}stopping port-forwards...${NC}"
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

forward() {
  local target=$1 local_port=$2 remote_port=$3 label=$4
  kubectl port-forward -n "$NS" "$target" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  PIDS+=($!)
  echo -e "  ${GREEN}✓${NC} ${label}  ${CYAN}http://localhost:${local_port}${NC}"
}

echo ""
echo -e "${BOLD}Port-forwards${NC}"
forward svc/mcp-federation-gateway 8080 80   "MCP gateway "
forward svc/keycloak               8081 8080 "Keycloak    "
forward svc/prometheus             9090 9090 "Prometheus  "
echo ""
echo -e "  ${DIM}Keycloak admin console: http://localhost:8081  (admin / admin)${NC}"
echo -e "  ${DIM}Leave this running. Ctrl-C to stop.${NC}"
echo ""

# Surface a forward that dies (a restarted pod, usually) instead of leaving the
# demo scripts to fail with a confusing connection error.
while true; do
  for pid in "${PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo -e "  ${DIM}a port-forward dropped — restarting it is usually enough:${NC} ./port-forward.sh"
      cleanup
    fi
  done
  sleep 5
done
