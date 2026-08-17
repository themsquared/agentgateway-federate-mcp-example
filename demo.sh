#!/usr/bin/env bash
#
# Federated MCP on agentgateway — interactive walkthrough
#
# Builds the story in the order the capabilities matter:
#
#   Act 1  Federation      six MCP servers behind three endpoints
#   Act 2  Authentication  three OAuth providers, one gateway
#   Act 3  Authorization   per-company tool entitlements
#   Act 4  Quotas          per-company rate limits
#   Act 5  Metering        usage and chargeback by customer
#   Act 6  Onboarding      adding the fourth partner
#
# Every resource shown on screen is read from — and applied from — the real file
# under manifests/. There is no hidden configuration: what you see is what runs.
#
# Prerequisites: ./setup.sh has completed and ./port-forward.sh is running.
#
# Usage:
#   ./demo.sh              full walkthrough
#   ./demo.sh --act 3      reset, fast-forward acts 1-2 silently, then play act 3
#   ./demo.sh --reset      restore the fully-configured state and exit
#
# Press Enter to advance. Ctrl-C to quit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/manifests"
SCRIPTS="${SCRIPT_DIR}/scripts"
NS="${DEMO_NS:-mcp-federation}"

# URL resolution, most specific wins: explicit env > .ports.env (written by a
# running ./port-forward.sh, so non-default ports Just Work) > defaults.
if [ -f "${SCRIPT_DIR}/.ports.env" ]; then
  while IFS='=' read -r k v; do
    case "$k" in GATEWAY_URL|KEYCLOAK_URL|PROMETHEUS_URL)
      eval "export ${k}=\"\${${k}:-${v}}\"" ;;
    esac
  done < "${SCRIPT_DIR}/.ports.env"
fi
export GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
export KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8180}"
export PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RED='\033[0;31m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'
NC='\033[0m'; BG_BLUE='\033[44m'

STEP_NUM=0
SILENT=false

pause() {
  [ "$SILENT" = "true" ] && return 0
  echo ""
  echo -en "  ${DIM}[ Press Enter to continue ]${NC}"
  read -r
  echo ""
}

act() {
  local num=$1; shift
  local title="$*"
  STEP_NUM=0
  if [ "$SILENT" = "true" ]; then
    echo -e "${DIM}▶ fast-forwarding Act ${num} — ${title}...${NC}"
    return 0
  fi
  # Pad to a fixed banner width. ${#title} is the length of the joined title —
  # ${#*} would be the number of arguments, which silently over-pads.
  local text="   ACT ${num}: ${title}"
  local pad=$((68 - ${#text}))
  [ $pad -lt 0 ] && pad=0
  clear
  echo ""
  echo -e "${BG_BLUE}${WHITE}$(printf '%68s' '')${NC}"
  echo -e "${BG_BLUE}${WHITE}${text}$(printf '%*s' $pad '')${NC}"
  echo -e "${BG_BLUE}${WHITE}$(printf '%68s' '')${NC}"
  echo ""
  pause
}

scene() {
  STEP_NUM=$((STEP_NUM + 1))
  [ "$SILENT" = "true" ] && return 0
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  ${STEP_NUM}. $*${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

narrate() { [ "$SILENT" = "true" ] && return 0; echo -e "  ${DIM}$*${NC}"; }
callout() { [ "$SILENT" = "true" ] && return 0; echo -e "  ${YELLOW}▸ $*${NC}"; }
check_ok() { echo -e "  ${GREEN}✓ $*${NC}"; }

# Show the real manifest — this is the exact file apply_file applies.
show_file() {
  local f=$1
  local rel="manifests/${f#"${MANIFESTS}"/}"
  [ "$SILENT" = "true" ] && { echo -e "  ${DIM}📄 ${rel}${NC}"; return 0; }
  echo -e "  ${BOLD}📄 ${rel}${NC}"
  echo -e "  ${MAGENTA}┌────────────────────────────────────────────────────────${NC}"
  # Strip the long comment preamble; the file is on disk to read in full.
  grep -v '^#' "$f" | sed '/^$/N;/^\n$/D' | while IFS= read -r line; do
    echo -e "  ${MAGENTA}│${NC} ${line}"
  done
  echo -e "  ${MAGENTA}└────────────────────────────────────────────────────────${NC}"
}

apply_file() {
  local f=$1
  local rel="manifests/${f#"${MANIFESTS}"/}"
  echo -e "  ${YELLOW}\$ kubectl apply -f ${rel}${NC}"
  kubectl apply -f "$f" 2>&1 | sed 's/^/    /'
}

run_cmd() {
  echo -e "  ${YELLOW}\$ $*${NC}"
  echo ""
  eval "$@" 2>&1 | sed 's/^/  /'
}

# Policies take a moment to reach the proxy through xDS.
settle() { sleep "${1:-6}"; }

###############################################################################
# Preflight
###############################################################################
preflight() {
  # Check all three up front — and check they are the RIGHT services, not just
  # that something answers. A stale port-forward from another project on the
  # same port answers with a 404, and a preflight that accepts any HTTP
  # response would then let the reset below tear down policies while every
  # later step talks to the wrong backend. (This happened. Once.)
  local failed=""
  # Keycloak: the acme realm endpoint returns JSON naming the realm.
  curl -sf --max-time 5 "${KEYCLOAK_URL}/realms/acme" 2>/dev/null | grep -q '"realm":"acme"' \
    || failed="${failed}\n  Keycloak     ${KEYCLOAK_URL}  (expected the 'acme' realm to answer)"
  # Gateway: unauthenticated POST to a federated route must reach agentgateway —
  # 401 (authn on) and 200 (authn not yet applied) are both ours; 404 is not.
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "${GATEWAY_URL}/mcp/billing" \
           -H 'Content-Type: application/json' -d '{}' 2>/dev/null) || code=000
  case "$code" in 200|202|400|401|406|415|429) ;; *)
    failed="${failed}\n  MCP gateway  ${GATEWAY_URL}  (got HTTP ${code} from /mcp/billing — wrong service?)" ;;
  esac
  curl -sf -o /dev/null --max-time 5 "${PROMETHEUS_URL}/-/ready" 2>/dev/null \
    || failed="${failed}\n  Prometheus   ${PROMETHEUS_URL}"
  if [ -n "$failed" ]; then
    echo ""
    echo -e "${RED}Preflight failed:${NC}${failed}"
    echo ""
    echo -e "${DIM}Start the port-forwards in another terminal:${NC}  ./port-forward.sh"
    echo -e "${DIM}If you run them on other ports, export GATEWAY_URL / KEYCLOAK_URL / PROMETHEUS_URL to match.${NC}"
    echo ""
    exit 1
  fi
}

###############################################################################
# Reset — return to the "federation only, no policies" starting state
###############################################################################
reset_to_baseline() {
  kubectl delete agentgatewaypolicy company-jwt-authentication -n "$NS" --ignore-not-found >/dev/null 2>&1
  kubectl delete agentgatewaypolicy billing-entitlements       -n "$NS" --ignore-not-found >/dev/null 2>&1
  kubectl delete agentgatewaypolicy analytics-entitlements     -n "$NS" --ignore-not-found >/dev/null 2>&1
  kubectl delete agentgatewaypolicy support-entitlements       -n "$NS" --ignore-not-found >/dev/null 2>&1
  kubectl delete agentgatewaypolicy chargeback-metrics         -n "$NS" --ignore-not-found >/dev/null 2>&1
  kubectl delete enterpriseagentgatewaypolicy company-quotas   -n "$NS" --ignore-not-found >/dev/null 2>&1
  kubectl delete ratelimitconfig company-quotas                -n "$NS" --ignore-not-found >/dev/null 2>&1
}

restore_all() {
  kubectl apply -f "${MANIFESTS}/security/"      >/dev/null 2>&1
  kubectl apply -f "${MANIFESTS}/quotas/"        >/dev/null 2>&1
  kubectl apply -f "${MANIFESTS}/observability/" >/dev/null 2>&1
}

###############################################################################
# Acts
###############################################################################

act1_federation() {
  act 1 "Federation — six servers, three endpoints"

  scene "The estate we are putting behind a gateway"
  narrate "Six independent MCP servers, owned by different teams, grouped into three"
  narrate "business domains. Each is an ordinary MCP server that knows nothing about"
  narrate "companies, tokens, quotas, or billing."
  echo ""
  run_cmd "kubectl get deploy -n ${NS} -l mcp-domain -o custom-columns=SERVER:.metadata.name,DOMAIN:'.metadata.labels.mcp-domain',READY:.status.readyReplicas"
  pause

  scene "One AgentgatewayBackend per business domain"
  narrate "Each backend fans one endpoint out across several servers. A consumer connects"
  narrate "once to /mcp/billing and sees the union of the payments and invoicing tools."
  echo ""
  show_file "${MANIFESTS}/federation/backends.yaml"
  pause

  scene "Three federated endpoints on one gateway"
  show_file "${MANIFESTS}/federation/gateway.yaml"
  apply_file "${MANIFESTS}/federation/backends.yaml"
  apply_file "${MANIFESTS}/federation/gateway.yaml"
  settle 4
  pause

  scene "What a client sees on a single connection"
  narrate "Tools arrive namespaced as <server>_<tool>, so two servers can both have a"
  narrate "'get_invoice' without colliding."
  run_cmd "${SCRIPTS}/mcp.py list acme billing"
  callout "Ten tools, two servers, one connection — and no authentication yet."
  callout "Right now anyone who can reach this endpoint can call anything. That is Act 2."
  pause
}

act2_authentication() {
  act 2 "Authentication — three OAuth providers, one gateway"

  scene "Three companies, three identity providers"
  narrate "Acme, Globex and Initech each authenticate against their OWN realm, with their"
  narrate "own signing keys. To the gateway these are three independent OIDC issuers."
  echo ""
  run_cmd "${SCRIPTS}/mcp.py token acme | head -6"
  narrate "The two claims that matter downstream: 'company' decides what you may call,"
  narrate "'tier' decides how much."
  pause

  scene "Turning on JWT validation"
  show_file "${MANIFESTS}/security/01-jwt-authentication.yaml"
  pause

  scene "Apply it"
  apply_file "${MANIFESTS}/security/01-jwt-authentication.yaml"
  settle
  pause

  scene "Anonymous access is now closed"
  echo -e "  ${YELLOW}\$ curl -s -X POST ${GATEWAY_URL}/mcp/billing -d '{...}' ${DIM}(no Authorization header)${NC}"
  echo ""
  curl -s -o /dev/null -w "    HTTP %{http_code}\n" -X POST "${GATEWAY_URL}/mcp/billing" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"anon","version":"1"}}}'
  echo ""
  check_ok "401 — no token, no entry"
  echo ""
  narrate "With a valid token from any of the three realms, the same request succeeds:"
  run_cmd "${SCRIPTS}/mcp.py list initech billing"
  callout "Initech authenticated successfully — and still sees all ten billing tools."
  callout "Authentication proves WHO you are. It says nothing about what you may do."
  pause
}

act3_authorization() {
  act 3 "Authorization — per-company tool entitlements"

  scene "The entitlement contract, in git"
  narrate "One expression per company per server. Expressions are OR'd: allowed if any"
  narrate "matches, denied if none do. Note mcp.tool.name is the ORIGIN tool name, and"
  narrate "mcp.tool.target scopes it to one server in the federation."
  echo ""
  show_file "${MANIFESTS}/security/02-authorization-billing.yaml"
  pause

  scene "Apply all three domains"
  apply_file "${MANIFESTS}/security/02-authorization-billing.yaml"
  apply_file "${MANIFESTS}/security/03-authorization-analytics.yaml"
  apply_file "${MANIFESTS}/security/04-authorization-support.yaml"
  settle 8
  pause

  scene "The same three URLs, three different views"
  run_cmd "${SCRIPTS}/mcp.py matrix"
  callout "Initech now sees zero billing tools. Globex sees four — read-only."
  callout "Globex can export datasets; Acme, the enterprise account, cannot. Entitlements"
  callout "follow the contract, not a tier ladder."
  pause

  scene "A tool you are not entitled to is invisible, not just blocked"
  run_cmd "${SCRIPTS}/mcp.py call globex billing payments_create_charge '{\"customer_id\":\"cus_1\",\"amount_cents\":5000}' || true"
  callout "'Unknown tool' — Globex cannot even confirm the capability exists."
  echo ""
  narrate "Nobody at all can reach payments.void_transaction or crm.delete_customer."
  narrate "They are implemented and running; the gateway is what makes them unreachable."
  pause
}

act4_quotas() {
  act 4 "Quotas — enforceable per company"

  scene "A quota table keyed on the company claim"
  narrate "Counters live in the shared Redis that ships with the enterprise install, so a"
  narrate "quota is enforced across every gateway replica — 20/min means 20/min in total,"
  narrate "not 20 per replica. That is the difference between a contractual number and a"
  narrate "number that silently multiplies."
  echo ""
  show_file "${MANIFESTS}/quotas/company-quotas.yaml"
  pause

  scene "Apply it"
  apply_file "${MANIFESTS}/quotas/company-quotas.yaml"
  settle 10
  pause

  scene "Initech is on the trial tier: 20 requests per minute"
  run_cmd "${SCRIPTS}/mcp.py quota initech 25"
  callout "Throttled at the gateway — the MCP servers never saw the excess traffic."
  pause

  scene "Acme is on enterprise: 600 per minute, and is unaffected"
  run_cmd "${SCRIPTS}/mcp.py quota acme 8"
  callout "One noisy tenant cannot spend another tenant's allowance."
  pause
}

act5_metering() {
  act 5 "Metering — usage and chargeback by customer"

  scene "The metric agentgateway already emits"
  narrate "MCP calls are counted out of the box, broken down by server and tool. What is"
  narrate "missing is WHO called — without it you can see the platform is busy but you"
  narrate "cannot bill anyone."
  echo ""
  show_file "${MANIFESTS}/observability/01-metering-attributes.yaml"
  pause

  scene "Apply it, then generate some traffic"
  apply_file "${MANIFESTS}/observability/01-metering-attributes.yaml"
  settle 8
  echo ""
  narrate "Simulating a working day across all three customers..."
  generate_traffic
  check_ok "traffic generated"
  narrate "waiting for Prometheus to scrape..."
  sleep 10
  pause

  scene "The chargeback report"
  narrate "Every number below comes from one PromQL query. No MCP server knows about"
  narrate "billing, and no agent self-reports usage — the gateway is on the path, so it is"
  narrate "the one place usage can be counted in a way a customer cannot under-report."
  run_cmd "${SCRIPTS}/chargeback.py --by-tool"
  callout "Customer × domain × server × tool, priced from scripts/pricing.json."
  callout "Globex's dataset exports dominate its bill — that is the rate card working."
  pause

  scene "Same data, machine-readable for a billing pipeline"
  run_cmd "${SCRIPTS}/chargeback.py --csv | head -12"
  pause
}

generate_traffic() {
  local q=">/dev/null 2>&1"
  # Acme — a broad enterprise workload
  for _ in 1 2 3; do
    "${SCRIPTS}/mcp.py" call acme billing payments_get_payment '{"payment_id":"pay_10482"}' >/dev/null 2>&1
  done
  "${SCRIPTS}/mcp.py" call acme billing payments_create_charge '{"customer_id":"cus_8891","amount_cents":48200}' >/dev/null 2>&1
  "${SCRIPTS}/mcp.py" call acme billing invoicing_list_invoices '{"customer_id":"cus_8891"}' >/dev/null 2>&1
  "${SCRIPTS}/mcp.py" call acme analytics reporting_run_report '{"report_id":"rpt_arr_waterfall"}' >/dev/null 2>&1
  "${SCRIPTS}/mcp.py" call acme analytics telemetry_get_funnel '{"steps":["session_start","checkout_completed"]}' >/dev/null 2>&1
  "${SCRIPTS}/mcp.py" call acme support tickets_create_ticket '{"customer_id":"cus_8891","subject":"Webhook 401s"}' >/dev/null 2>&1
  "${SCRIPTS}/mcp.py" call acme support crm_get_customer '{"customer_id":"cus_8891"}' >/dev/null 2>&1
  # Globex — analytics-heavy, including the expensive export
  "${SCRIPTS}/mcp.py" call globex analytics reporting_export_dataset '{"dataset":"fact_transactions"}' >/dev/null 2>&1
  "${SCRIPTS}/mcp.py" call globex analytics reporting_run_report '{"report_id":"rpt_cohort_retention"}' >/dev/null 2>&1
  "${SCRIPTS}/mcp.py" call globex analytics telemetry_query_events '{"event_type":"checkout_completed"}' >/dev/null 2>&1
  "${SCRIPTS}/mcp.py" call globex billing invoicing_get_invoice '{"invoice_id":"inv_2026_0182"}' >/dev/null 2>&1
  # Globex tries something it is not entitled to — shows up as a denial, not a charge
  "${SCRIPTS}/mcp.py" call globex billing payments_refund_payment '{"payment_id":"pay_1"}' >/dev/null 2>&1
  # Initech — light trial usage
  "${SCRIPTS}/mcp.py" call initech analytics reporting_get_kpi_summary '{}' >/dev/null 2>&1
  "${SCRIPTS}/mcp.py" call initech support tickets_search_tickets '{"query":"login"}' >/dev/null 2>&1
}

act6_onboarding() {
  act 6 "Onboarding — adding the fourth partner"

  scene "What it takes to add a new customer"
  narrate "Everything you have seen keys off two claims on a token. Onboarding a partner is"
  narrate "therefore a bounded, repeatable change — no new endpoints, no new servers, and"
  narrate "no change to anything an existing customer touches."
  echo ""
  echo -e "  ${BOLD}1.${NC} Their IdP           add an issuer + JWKS URL to the authn policy"
  echo -e "  ${BOLD}2.${NC} Their entitlements  add one line per domain they bought"
  echo -e "  ${BOLD}3.${NC} Their quota         add one descriptor row"
  echo -e "  ${BOLD}4.${NC} Their billing       nothing — metering keys off the same claim"
  echo ""
  callout "Their IdP does not have to be Keycloak. agentgateway validates any OIDC"
  callout "issuer — Okta, Entra, Auth0, Descope, Authentik — it is a URL and a JWKS."
  pause

  scene "There is a script for it"
  narrate "scripts/add-partner.sh generates the realm, the policy edits and the quota row,"
  narrate "so the repeatable part is actually repeated rather than hand-copied."
  echo ""
  run_cmd "${SCRIPTS}/add-partner.sh --help"
  pause

  scene "Full runbook"
  narrate "ONBOARDING.md walks the whole process, including using a partner's own Okta or"
  narrate "Entra tenant instead of a realm here, and how to stage it safely."
  echo ""
  echo -e "  ${BOLD}ONBOARDING.md${NC}   rinse-and-repeat partner onboarding"
  echo -e "  ${BOLD}PRODUCTION.md${NC}   mapping this to a real estate: 50 IdPs, domains, per-user quotas"
  echo -e "  ${BOLD}WALKTHROUGH.md${NC}  how the whole thing is built, layer by layer"
  echo -e "  ${BOLD}README.md${NC}       architecture and repo map"
  pause
}

finale() {
  clear
  echo ""
  echo -e "${BG_BLUE}${WHITE}                                                                    ${NC}"
  echo -e "${BG_BLUE}${WHITE}   Federated MCP on agentgateway — recap                            ${NC}"
  echo -e "${BG_BLUE}${WHITE}                                                                    ${NC}"
  echo ""
  echo -e "  ${GREEN}✓${NC} ${BOLD}Federation${NC}      6 MCP servers → 3 business endpoints, 1 connection each"
  echo -e "  ${GREEN}✓${NC} ${BOLD}Authentication${NC}  3 independent OAuth providers validated at the gateway"
  echo -e "  ${GREEN}✓${NC} ${BOLD}Authorization${NC}   per-company tool visibility and use, denied by default"
  echo -e "  ${GREEN}✓${NC} ${BOLD}Quotas${NC}          per-company limits enforced fleet-wide via Redis"
  echo -e "  ${GREEN}✓${NC} ${BOLD}Metering${NC}        usage by customer × domain × server × tool, priced"
  echo -e "  ${GREEN}✓${NC} ${BOLD}Onboarding${NC}      a new partner is a policy change, not a deployment"
  echo ""
  echo -e "  ${DIM}The MCP servers contain no authentication, authorization, quota or billing${NC}"
  echo -e "  ${DIM}code. Every one of those properties was added at the gateway, declaratively,${NC}"
  echo -e "  ${DIM}without touching them.${NC}"
  echo ""
  echo -e "  ${BOLD}Explore:${NC}"
  echo -e "    scripts/mcp.py matrix"
  echo -e "    scripts/chargeback.py --by-tool"
  echo -e "    less WALKTHROUGH.md    ${DIM}# start-to-finish build${NC}"
  echo -e "    less ONBOARDING.md     ${DIM}# adding the next partner${NC}"
  echo ""
}

###############################################################################
# Main
###############################################################################
START_ACT=1
case "${1:-}" in
  --reset)
    echo "Restoring the fully-configured state..."
    restore_all
    echo "Done — all policies applied."
    exit 0
    ;;
  --act)
    START_ACT="${2:-1}"
    ;;
  "") ;;
  *) sed -n '2,26p' "$0"; exit 0 ;;
esac

preflight
reset_to_baseline
settle 4

for n in 1 2 3 4 5 6; do
  if [ "$n" -lt "$START_ACT" ]; then SILENT=true; else SILENT=false; fi
  case $n in
    1) act1_federation ;;
    2) act2_authentication ;;
    3) act3_authorization ;;
    4) act4_quotas ;;
    5) act5_metering ;;
    6) act6_onboarding ;;
  esac
done

SILENT=false
finale
