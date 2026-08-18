#!/usr/bin/env bash
#
# Federated MCP on agentgateway — environment setup
#
# Builds the whole demo from nothing:
#   - a k3d cluster (or reuses your current kube context)
#   - Gateway API CRDs
#   - Solo Enterprise agentgateway (control plane, rate limiter, Redis)
#   - Keycloak with three company realms  (Acme / Globex / Initech)
#   - six stub MCP servers in three business domains
#   - the federation, authn, authorization, quota and metering policies
#   - a small Prometheus for the chargeback report
#
# Everything declarative lives in manifests/ and is applied with kubectl. The
# only things created imperatively are the license secret and the ConfigMap
# holding mcp-server/server.py, because both are generated from files on disk.
#
# Prerequisites:
#   - kubectl, helm  (and k3d, unless you pass --use-current-context)
#   - a Solo agentgateway license key — set AGENTGATEWAY_LICENSE_KEY or
#     SOLO_LICENSE_KEY in .env, or paste it when prompted
#
# Usage:
#   ./setup.sh                          # create a k3d cluster and install
#   ./setup.sh --use-current-context    # install into whatever kubectl points at
#   ./setup.sh --skip-install           # only (re)apply manifests/ — fast iteration
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/manifests"

# .env is gitignored; it holds the license key and any overrides.
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a; . "${SCRIPT_DIR}/.env"; set +a
fi

CLUSTER_NAME="${CLUSTER_NAME:-mcp-federation}"
AGW_VERSION="${AGW_VERSION:-v2026.8.0}"
UI_VERSION="${UI_VERSION:-0.5.4}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.0}"
AGW_NS="${AGW_NS:-agentgateway-system}"
DEMO_NS="${DEMO_NS:-mcp-federation}"

USE_CURRENT_CONTEXT=false
SKIP_INSTALL=false
INSTALL_UI=true
for arg in "$@"; do
  case "$arg" in
    --use-current-context) USE_CURRENT_CONTEXT=true ;;
    --skip-install)        SKIP_INSTALL=true; USE_CURRENT_CONTEXT=true ;;
    --no-ui)               INSTALL_UI=false ;;
    -h|--help)             sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg (try --help)"; exit 1 ;;
  esac
done

# ANSI-C quoting ($'...') puts real escape characters in these variables, so they
# render both through `echo -e` and inside the final heredoc, which does no
# escape processing of its own.
BOLD=$'\033[1m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'
RED=$'\033[0;31m'; DIM=$'\033[2m'; NC=$'\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()    { echo -e "${RED}[ERROR]${NC} $*"; }
header() { echo -e "\n${BOLD}═══════════════════════════════════════════════════${NC}"
           echo -e "${BOLD}  $*${NC}"
           echo -e "${BOLD}═══════════════════════════════════════════════════${NC}\n"; }

###############################################################################
# Preflight
###############################################################################
header "Preflight"

REQUIRED=(kubectl helm)
[ "$USE_CURRENT_CONTEXT" = "false" ] && REQUIRED+=(k3d)
for cmd in "${REQUIRED[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || { err "$cmd is required but not found"; exit 1; }
  ok "$cmd found"
done
command -v python3 >/dev/null 2>&1 || warn "python3 not found — scripts/mcp.py and the demo need it"

if [ "$SKIP_INSTALL" = "false" ]; then
  # One license covers the install. Accept either the product-specific key or a
  # single trial key covering several Solo products.
  AGENTGATEWAY_LICENSE_KEY="${AGENTGATEWAY_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}"
  if [ -z "${AGENTGATEWAY_LICENSE_KEY}" ]; then
    echo ""
    warn "No license key found (AGENTGATEWAY_LICENSE_KEY or SOLO_LICENSE_KEY)."
    echo -e "  ${DIM}Copy .env.example to .env and add yours, or paste it now.${NC}"
    read -rp "  License key: " AGENTGATEWAY_LICENSE_KEY
    [ -z "${AGENTGATEWAY_LICENSE_KEY}" ] && { err "a license key is required"; exit 1; }
  fi
  ok "license key present"
fi

###############################################################################
# Cluster
###############################################################################
if [ "$USE_CURRENT_CONTEXT" = "true" ]; then
  header "Cluster"
  CTX="$(kubectl config current-context)"
  info "Using current context: ${BOLD}${CTX}${NC}"
  kubectl get nodes >/dev/null 2>&1 || { err "cannot reach the cluster"; exit 1; }
  ok "cluster reachable"
else
  header "Cluster: k3d '${CLUSTER_NAME}'"
  if k3d cluster list 2>/dev/null | grep -qE "^${CLUSTER_NAME}\s"; then
    info "Cluster '${CLUSTER_NAME}' already exists — reusing it"
  else
    info "Creating k3d cluster '${CLUSTER_NAME}'..."
    k3d cluster create "${CLUSTER_NAME}" \
      --agents 1 \
      --k3s-arg "--disable=traefik@server:0" \
      --wait
  fi
  kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
  ok "cluster ready"
fi

###############################################################################
# agentgateway
###############################################################################
if [ "$SKIP_INSTALL" = "false" ]; then
  header "Gateway API CRDs (${GATEWAY_API_VERSION})"
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  ok "Gateway API installed"

  header "Solo Enterprise agentgateway (${AGW_VERSION})"
  info "Installing CRDs..."
  helm upgrade -i enterprise-agentgateway-crds \
    oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
    --create-namespace --namespace "${AGW_NS}" \
    --version "${AGW_VERSION}"

  # No discoveryNamespaceSelectors override here on purpose: the controller must
  # be able to see the demo namespace. If you install agentgateway yourself with
  # a namespace selector, label the demo namespace to match or the Gateway will
  # sit at "Waiting for controller" forever.
  info "Installing control plane, rate limiter and cache..."
  helm upgrade -i enterprise-agentgateway \
    oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
    --namespace "${AGW_NS}" \
    --version "${AGW_VERSION}" \
    --set-string "licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY}" \
    --wait --timeout 5m

  kubectl rollout status deploy/enterprise-agentgateway -n "${AGW_NS}" --timeout=180s
  ok "agentgateway control plane is running"
fi

###############################################################################
# Demo workloads
###############################################################################
header "MCP servers, identity providers and policies"

kubectl apply -f "${MANIFESTS}/00-namespace.yaml"

# If agentgateway was installed with discoveryNamespaceSelectors (common on a
# shared cluster that already runs other demos), its controller ignores every
# namespace that does not match — and a Gateway here would sit at "Waiting for
# controller" until the timeout with no obvious cause. Detect that and label the
# namespace so it is discovered.
SELECTORS="$(kubectl get deploy enterprise-agentgateway -n "${AGW_NS}" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AGW_DISCOVERY_NAMESPACE_SELECTORS")].value}' 2>/dev/null || true)"
if [ -n "${SELECTORS}" ] && [ "${SELECTORS}" != "[]" ]; then
  LABELS="$(printf '%s' "${SELECTORS}" | python3 -c '
import json, sys
try:
    sel = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# Only matchLabels can be satisfied by labelling; matchExpressions needs a human.
print(" ".join(f"{k}={v}" for entry in sel for k, v in (entry.get("matchLabels") or {}).items()))
' 2>/dev/null || true)"
  if [ -n "${LABELS}" ]; then
    warn "agentgateway restricts discovery to selected namespaces."
    info "  labelling ${DEMO_NS} with: ${LABELS}"
    # shellcheck disable=SC2086
    kubectl label namespace "${DEMO_NS}" ${LABELS} --overwrite >/dev/null
    ok "namespace is discoverable by the controller"
  else
    warn "agentgateway uses discoveryNamespaceSelectors that cannot be satisfied by"
    warn "labels alone (${SELECTORS}). If the Gateway never programs, make sure the"
    warn "'${DEMO_NS}' namespace matches that selector."
  fi
fi

# The six MCP servers all run the same file from mcp-server/server.py. Shipping
# it as a real file (rather than pasted into a YAML string) means you can read
# it, edit it, and run it locally — and there is exactly one copy of it.
info "Publishing the MCP server code as a ConfigMap..."
kubectl create configmap mcp-server-code \
  --namespace "${DEMO_NS}" \
  --from-file=server.py="${SCRIPT_DIR}/mcp-server/server.py" \
  --dry-run=client -o yaml | kubectl apply -f -

# One JSON file per company in manifests/keycloak/realms/, built into a single
# ConfigMap that Keycloak imports at startup. Adding a company means adding a
# file — no existing realm is edited. See that directory's README.
info "Building the realm ConfigMap from manifests/keycloak/realms/..."
REALM_ARGS=()
for realm in "${MANIFESTS}"/keycloak/realms/*.json; do
  REALM_ARGS+=(--from-file="${realm}")   # *.json only — the directory's README must not become a key
done
[ ${#REALM_ARGS[@]} -eq 0 ] && { err "no realm files found in manifests/keycloak/realms/"; exit 1; }
info "  realms: $(basename -a "${MANIFESTS}"/keycloak/realms/*.json | sed 's/\.json//' | tr '\n' ' ')"
kubectl create configmap keycloak-realms \
  --namespace "${DEMO_NS}" \
  "${REALM_ARGS[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Deploying Keycloak..."
kubectl apply -f "${MANIFESTS}/keycloak/keycloak.yaml"

info "Deploying six stub MCP servers..."
kubectl apply -f "${MANIFESTS}/mcp-servers/"

info "Creating the federation (three virtual MCP servers) and its gateway..."
kubectl apply -f "${MANIFESTS}/federation/"

info "Applying authentication and per-company tool entitlements..."
kubectl apply -f "${MANIFESTS}/security/"

info "Applying per-company quotas..."
kubectl apply -f "${MANIFESTS}/quotas/"

info "Applying metering attributes and Prometheus..."
kubectl apply -f "${MANIFESTS}/observability/"

###############################################################################
# Solo Enterprise UI (the agentgateway dashboard)
###############################################################################
if [ "$INSTALL_UI" = "true" ] && [ "$SKIP_INSTALL" = "false" ]; then
  header "Solo Enterprise UI (management chart ${UI_VERSION})"

  # No wait-for-Keycloak here on purpose. The UI backend retries OIDC discovery
  # against the platform realm until it answers, so installing in parallel with
  # Keycloak's first boot is safe — and on a fresh cluster with cold image
  # caches, serializing on Keycloak here is exactly where a first run stalls.
  # The readiness section below is what actually gates on everything being up.

  # Agentgateway product only — no kagent, no mesh. istio.ambient is disabled
  # because this cluster runs no mesh; leaving it on labels pods for a dataplane
  # that does not exist. The chart also deploys the telemetry collector and
  # ClickHouse that back the UI's traffic and tracing views (manifests/ui/
  # tracing.yaml points the gateway's spans at that collector).
  info "Installing the UI into ${AGW_NS}..."
  helm upgrade -i agentgateway-ui \
    oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
    -n "${AGW_NS}" \
    --version "${UI_VERSION}" \
    --set cluster=mgmt-cluster \
    --set products.agentgateway.enabled=true \
    --set 'products.agentgateway.features.cost-management=true' \
    --set 'products.agentgateway.features.cost-management-writes=true' \
    --set istio.ambient.enabled=false \
    --set-string "licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY}" \
    --set-string "oidc.issuer=http://keycloak.${DEMO_NS}.svc.cluster.local:8180/realms/platform" \
    --set-string "ui.backend.oidc.clientId=agw-ui-backend" \
    --set-string "ui.backend.oidc.secret=agw-ui-backend-secret" \
    --set-string "ui.frontend.oidc.clientId=agw-ui-frontend"

  info "Wiring gateway tracing to the UI's telemetry collector..."
  kubectl apply -f "${MANIFESTS}/ui/"
elif [ "$INSTALL_UI" = "true" ]; then
  # --skip-install re-applies manifests only; keep the tracing policy in sync if
  # the UI is already present, and skip it cleanly if it never was.
  if kubectl get svc solo-enterprise-telemetry-collector -n "${AGW_NS}" >/dev/null 2>&1; then
    kubectl apply -f "${MANIFESTS}/ui/"
  else
    info "UI not installed — skipping manifests/ui/ (run without --skip-install to add it)"
  fi
fi

###############################################################################
# Wait for readiness
###############################################################################
header "Waiting for everything to come up"

# A readiness timeout must fail LOUDLY. Under `set -e` a bare `kubectl rollout
# status` timeout would kill the script mid-sentence with one cryptic line and
# skip everything after it — including this section's remaining checks and the
# final instructions. Print what is actually wrong and say the script is safe to
# re-run (it is idempotent; a re-run picks up where the images left off).
wait_ready() {
  local kind_name=$1 ns=$2 timeout=$3 label=$4
  if kubectl rollout status "$kind_name" -n "$ns" --timeout="$timeout" >/dev/null 2>&1; then
    ok "$label"
  else
    err "$label did not become ready within ${timeout}."
    kubectl get pods -n "$ns" 2>/dev/null | sed 's/^/    /'
    echo ""
    err "First runs pull several images; on slow links a wait can expire before"
    err "the pull finishes. setup.sh is idempotent — re-run it to resume."
    exit 1
  fi
}

info "MCP servers..."
for d in payments invoicing reporting telemetry tickets crm; do
  wait_ready "deploy/mcp-${d}" "${DEMO_NS}" 300s "mcp-${d}"
done

info "Keycloak (first boot pulls the image and imports four realms)..."
wait_ready deploy/keycloak "${DEMO_NS}" 600s "keycloak"

info "Prometheus..."
wait_ready deploy/prometheus "${DEMO_NS}" 300s "prometheus"

info "Gateway (the proxy is created by the controller once the Gateway is accepted)..."
DEADLINE=$((SECONDS + 240))
until kubectl get gateway mcp-federation-gateway -n "${DEMO_NS}" \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null | grep -q True; do
  if [ $SECONDS -gt $DEADLINE ]; then
    err "Gateway was not programmed within 240s."
    echo -e "  ${DIM}Check:  kubectl describe gateway mcp-federation-gateway -n ${DEMO_NS}${NC}"
    echo -e "  ${DIM}If it says \"Waiting for controller\", the agentgateway controller is not${NC}"
    echo -e "  ${DIM}watching this namespace — see the discoveryNamespaceSelectors note above.${NC}"
    exit 1
  fi
  sleep 4
done
ok "gateway programmed"

wait_ready deploy/mcp-federation-gateway "${DEMO_NS}" 300s "gateway proxy"

if [ "$INSTALL_UI" = "true" ] && kubectl get deploy solo-enterprise-ui -n "${AGW_NS}" >/dev/null 2>&1; then
  # Generous on purpose: on a completely cold cluster ClickHouse's first boot
  # can take 10+ minutes, and the UI backend crash-loops (by design) until it
  # answers. Measured ~11 minutes on a fresh k3d cluster; the stack self-heals,
  # so even a timeout here resolves itself — wait_ready's re-run advice stands.
  info "Solo Enterprise UI (ClickHouse first boot can take ~10 minutes on a cold cluster)..."
  wait_ready deploy/solo-enterprise-ui "${AGW_NS}" 900s "UI"
fi

###############################################################################
# Done
###############################################################################
header "Setup complete"

cat <<EOF
  Three companies, three OAuth realms, three federated MCP endpoints:

    ${BOLD}/mcp/billing${NC}     payments + invoicing
    ${BOLD}/mcp/analytics${NC}   reporting + telemetry
    ${BOLD}/mcp/support${NC}     tickets + crm

  Next:

    ${BOLD}1.${NC} Open the port-forwards (leave this running in another terminal):

         ./port-forward.sh

    ${BOLD}2.${NC} Run the guided walkthrough:

         ./demo.sh

    Or explore directly:

         scripts/mcp.py matrix
         scripts/mcp.py list acme billing
         scripts/mcp.py call globex analytics reporting_export_dataset '{"dataset":"fact_transactions"}'
         scripts/chargeback.py --by-tool

    ${BOLD}UI${NC} (agentgateway dashboard): http://localhost:9080 after ./port-forward.sh —
    login operator / operator. Browser SSO needs a one-time hosts entry:

         echo "127.0.0.1 keycloak.${DEMO_NS}.svc.cluster.local" | sudo tee -a /etc/hosts

EOF
