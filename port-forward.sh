#!/usr/bin/env bash
#
# Open the port-forwards the demo expects, and hold them open.
#
#   MCP gateway  → localhost:${GATEWAY_PORT:-8080}
#   Keycloak     → localhost:${KEYCLOAK_PORT:-8180}
#   Prometheus   → localhost:${PROMETHEUS_PORT:-9090}
#   UI           → localhost:${UI_PORT:-9080}        (when installed)
#
# Keycloak's local port matches its in-cluster port (8180) on purpose: the OIDC
# issuer URL embeds that port, and UI browser SSO works by resolving the issuer
# hostname to 127.0.0.1 (one-time /etc/hosts entry, printed below) — so the
# browser must find Keycloak on the very same port the issuer names.
#
# Run this in its own terminal and leave it running. Ctrl-C stops all three.
#
# If a default port is already taken on your machine (Docker and dev servers
# love 8080), either free it or override here — the script prints the matching
# environment exports for scripts/mcp.py and scripts/chargeback.py:
#
#   GATEWAY_PORT=18080 KEYCLOAK_PORT=18180 PROMETHEUS_PORT=19090 ./port-forward.sh
#
# Note on Keycloak: tokens minted through this port-forward carry the in-cluster
# issuer, not localhost, because KC_HOSTNAME is pinned in the deployment. That is
# what lets a token you fetched from your laptop be accepted by the gateway.

set -euo pipefail

NS="${DEMO_NS:-mcp-federation}"
AGW_NS="${AGW_NS:-agentgateway-system}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-8180}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
UI_PORT="${UI_PORT:-9080}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The resolved URLs are written here for the other tools to discover, so running
# on non-default ports needs no manual exports: demo.sh, scripts/mcp.py and
# scripts/chargeback.py all read this file when the corresponding env var is not
# already set. Gitignored; removed again on shutdown.
PORTS_ENV="${SCRIPT_DIR}/.ports.env"

ERRDIR="$(mktemp -d)"
PIDS=()
LABELS=()

cleanup() {
  echo ""
  echo -e "${DIM}stopping port-forwards...${NC}"
  # ${PIDS[@]+...} guards the empty-array case — macOS ships bash 3.2, where
  # expanding an empty array under `set -u` is an "unbound variable" error.
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$ERRDIR"
  rm -f "$PORTS_ENV"
  exit "${1:-0}"
}
trap 'cleanup 0' INT TERM

# Name whatever is already listening on a port, so the error says "Docker has
# 8080", not just "failed". lsof exits non-zero when the port is FREE — the
# normal case — so it must not bubble through `set -e -o pipefail`.
port_holder() {
  command -v lsof >/dev/null 2>&1 || { echo "unknown (lsof not available)"; return 0; }
  { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR==2 {print $1 " (pid " $2 ")"}'
}

# A port already in use is the most common failure by far, and kubectl's error
# for it arrives asynchronously. Check up front so the message is immediate and
# names the culprit.
preflight() {
  local failed=0
  local specs=("MCP gateway:${GATEWAY_PORT}" "Keycloak:${KEYCLOAK_PORT}" "Prometheus:${PROMETHEUS_PORT}")
  [ "$UI_INSTALLED" = "true" ] && specs+=("UI:${UI_PORT}")
  for spec in "${specs[@]}"; do
    local label="${spec%:*}" port="${spec##*:}"
    local holder; holder="$(port_holder "$port")"
    if [ -n "$holder" ]; then
      echo -e "  ${RED}✗${NC} port ${BOLD}${port}${NC} (${label}) is already in use by ${BOLD}${holder}${NC}"
      failed=1
    fi
  done
  if [ "$failed" = "1" ]; then
    echo ""
    echo -e "  ${DIM}Free the port(s), or run on different ones — the demo scripts pick the${NC}"
    echo -e "  ${DIM}URLs up from the environment:${NC}"
    echo ""
    echo -e "    GATEWAY_PORT=18080 KEYCLOAK_PORT=18180 PROMETHEUS_PORT=19090 ./port-forward.sh"
    echo ""
    exit 1
  fi
}

# Start one forward, then wait until it is actually serving before claiming ✓.
# kubectl exits on a failed bind and prints why — surface that instead of hiding it.
forward() {
  local ns=$1 target=$2 local_port=$3 remote_port=$4 label=$5
  local errfile="${ERRDIR}/${local_port}.err"
  kubectl port-forward -n "$ns" "$target" "${local_port}:${remote_port}" >/dev/null 2>"$errfile" &
  local pid=$!
  for _ in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo -e "  ${RED}✗${NC} ${label}  failed to start:"
      sed 's/^/      /' "$errfile"
      local holder; holder="$(port_holder "$local_port")"
      [ -n "$holder" ] && echo -e "      ${DIM}port ${local_port} is held by ${holder}${NC}"
      cleanup 1
    fi
    # Ready when the local socket is listening.
    if (exec 3<>"/dev/tcp/127.0.0.1/${local_port}") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      break
    fi
    sleep 0.25
  done
  PIDS+=("$pid")
  LABELS+=("$label")
  echo -e "  ${GREEN}✓${NC} ${label}  ${CYAN}http://localhost:${local_port}${NC}"
}

# The UI is optional (setup.sh --no-ui skips it). Only forward it when present.
UI_INSTALLED=false
kubectl get svc solo-enterprise-ui -n "${AGW_NS}" >/dev/null 2>&1 && UI_INSTALLED=true

echo ""
echo -e "${BOLD}Port-forwards${NC} ${DIM}(namespace: ${NS})${NC}"
preflight
forward "$NS"     svc/mcp-federation-gateway "${GATEWAY_PORT}"    80   "MCP gateway "
forward "$NS"     svc/keycloak               "${KEYCLOAK_PORT}"   8180 "Keycloak    "
forward "$NS"     svc/prometheus             "${PROMETHEUS_PORT}" 9090 "Prometheus  "
if [ "$UI_INSTALLED" = "true" ]; then
  forward "$AGW_NS" svc/solo-enterprise-ui   "${UI_PORT}"         80   "UI          "
else
  echo -e "  ${DIM}· UI            not installed (setup.sh --no-ui) — skipping${NC}"
fi
echo ""

# Publish the resolved URLs for the other tools. demo.sh and the Python scripts
# read this file automatically, so non-default ports need no manual exports.
cat > "$PORTS_ENV" <<EOF
GATEWAY_URL=http://localhost:${GATEWAY_PORT}
KEYCLOAK_URL=http://localhost:${KEYCLOAK_PORT}
PROMETHEUS_URL=http://localhost:${PROMETHEUS_PORT}
EOF
if [ "${GATEWAY_PORT}" != "8080" ] || [ "${KEYCLOAK_PORT}" != "8180" ] || [ "${PROMETHEUS_PORT}" != "9090" ]; then
  echo -e "  ${DIM}Non-default ports — recorded in .ports.env; demo.sh and the scripts pick${NC}"
  echo -e "  ${DIM}them up automatically.${NC}"
  echo ""
fi
if [ "$UI_INSTALLED" = "true" ]; then
  echo -e "  ${BOLD}UI:${NC} http://localhost:${UI_PORT}  ${DIM}(login: operator / operator)${NC}"
  if [ "${KEYCLOAK_PORT}" = "8180" ]; then
    if ! grep -q "keycloak.${NS}.svc.cluster.local" /etc/hosts 2>/dev/null; then
      echo -e "  ${YELLOW}▸ UI browser login needs a one-time hosts entry (the OIDC issuer must${NC}"
      echo -e "  ${YELLOW}  resolve in your browser):${NC}"
      echo -e "      echo \"127.0.0.1 keycloak.${NS}.svc.cluster.local\" | sudo tee -a /etc/hosts"
    fi
  else
    echo -e "  ${YELLOW}▸ Keycloak is not on 8180 — UI browser SSO will fail. The browser must${NC}"
    echo -e "  ${YELLOW}  reach the issuer at its own port; keep KEYCLOAK_PORT=8180 to use the UI.${NC}"
  fi
  echo ""
fi
echo -e "  ${DIM}Keycloak admin console: http://localhost:${KEYCLOAK_PORT}  (admin / admin)${NC}"
echo -e "  ${DIM}Leave this running. Ctrl-C to stop.${NC}"
echo ""

# Surface a forward that dies later (a restarted pod, usually) with its actual
# error, instead of leaving the demo scripts to fail with a vague refusal.
while true; do
  for i in ${!PIDS[@]+"${!PIDS[@]}"}; do
    if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
      echo -e "  ${RED}✗${NC} the ${LABELS[$i]% } forward dropped:"
      sed 's/^/      /' "${ERRDIR}"/*.err 2>/dev/null | grep -v '^ *$' | tail -3
      echo -e "  ${DIM}(a restarted pod is the usual cause — rerun ./port-forward.sh)${NC}"
      cleanup 1
    fi
  done
  sleep 5
done
