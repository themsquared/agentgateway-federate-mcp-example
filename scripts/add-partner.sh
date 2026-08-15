#!/usr/bin/env bash
#
# add-partner.sh — onboard a new external partner or customer.
#
# Onboarding is deliberately a small, bounded change. Everything in this demo
# keys off two claims on a token, so a new partner needs:
#
#   1. an identity provider the gateway trusts   (a realm here, or THEIR IdP)
#   2. a line per business domain they bought    (their entitlements)
#   3. a quota row                                (optional — a default applies)
#   4. nothing for billing                        (metering keys off the same claim)
#
# This script does step 1 for you and prints exactly what to paste for steps 2-3.
# It never edits a policy file behind your back: entitlements are a commercial
# decision and belong in a reviewed pull request, not in a generator's output.
#
# Usage:
#   scripts/add-partner.sh --name umbrella --display "Umbrella Corp" \
#       --tier standard \
#       --domains analytics,support
#
#   scripts/add-partner.sh --name wayne --display "Wayne Enterprises" \
#       --tier enterprise --domains billing,analytics,support \
#       --external-issuer https://wayne.okta.com/oauth2/default
#
# Flags:
#   --name <slug>          lowercase identifier; becomes the `company` claim
#   --display "<name>"     human-readable name
#   --tier <t>             enterprise | standard | trial   (default: standard)
#   --domains <list>       comma-separated: billing,analytics,support
#   --external-issuer <url>  use the partner's OWN OIDC provider instead of
#                            creating a Keycloak realm here. JWKS is discovered at
#                            <issuer>/.well-known/openid-configuration unless you
#                            also pass --jwks-url.
#   --jwks-url <url>       explicit JWKS endpoint (with --external-issuer)
#   --quota <n>            requests/minute; omit to inherit the catch-all default
#   --apply                also apply the generated realm to the cluster
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REALMS_DIR="${REPO_DIR}/manifests/keycloak/realms"
NS="${DEMO_NS:-mcp-federation}"

KC_INTERNAL="http://keycloak.mcp-federation.svc.cluster.local:8080"

NAME=""; DISPLAY=""; TIER="standard"; DOMAINS=""; QUOTA=""
EXTERNAL_ISSUER=""; JWKS_URL=""; APPLY=false

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)            NAME="$2"; shift 2 ;;
    --display)         DISPLAY="$2"; shift 2 ;;
    --tier)            TIER="$2"; shift 2 ;;
    --domains)         DOMAINS="$2"; shift 2 ;;
    --quota)           QUOTA="$2"; shift 2 ;;
    --external-issuer) EXTERNAL_ISSUER="$2"; shift 2 ;;
    --jwks-url)        JWKS_URL="$2"; shift 2 ;;
    --apply)           APPLY=true; shift ;;
    -h|--help)         usage 0 ;;
    *) echo -e "${RED}unknown flag:${NC} $1"; usage 1 ;;
  esac
done

[ -z "$NAME" ] && { echo -e "${RED}--name is required${NC}\n"; usage 1; }
echo "$NAME" | grep -qE '^[a-z][a-z0-9-]*$' || {
  echo -e "${RED}--name must be lowercase alphanumeric/dashes${NC} (it becomes the 'company' claim)"; exit 1; }
[ -z "$DISPLAY" ] && DISPLAY="$NAME"
case "$TIER" in enterprise|standard|trial) ;; *)
  echo -e "${RED}--tier must be enterprise, standard or trial${NC}"; exit 1 ;; esac
[ -z "$DOMAINS" ] && { echo -e "${RED}--domains is required${NC} (e.g. analytics,support)"; exit 1; }

for d in ${DOMAINS//,/ }; do
  case "$d" in billing|analytics|support) ;; *)
    echo -e "${RED}unknown domain '$d'${NC} — expected billing, analytics or support"; exit 1 ;; esac
done

echo ""
echo -e "${BOLD}Onboarding: ${DISPLAY} (${NAME})${NC}"
echo -e "${DIM}tier=${TIER}  domains=${DOMAINS}${NC}"
echo ""

###############################################################################
# Step 1 — identity
###############################################################################
echo -e "${BOLD}${CYAN}Step 1 — Identity provider${NC}"
echo ""

if [ -n "$EXTERNAL_ISSUER" ]; then
  ISSUER="$EXTERNAL_ISSUER"
  [ -z "$JWKS_URL" ] && JWKS_URL="${EXTERNAL_ISSUER%/}/.well-known/jwks.json"
  echo -e "  Using the partner's own OIDC provider — no realm created here."
  echo -e "  ${DIM}issuer:${NC} ${ISSUER}"
  echo -e "  ${DIM}jwks:  ${NC} ${JWKS_URL}"
  echo ""
  echo -e "  ${YELLOW}▸${NC} The partner must emit ${BOLD}company=\"${NAME}\"${NC} and ${BOLD}tier=\"${TIER}\"${NC} claims,"
  echo -e "    and include ${BOLD}mcp-federation${NC} in the audience. In Okta that is a custom"
  echo -e "    claim on the authorization server; in Entra, an optional claim or app role."
  echo -e "  ${YELLOW}▸${NC} The gateway must be able to reach that JWKS URL from inside the cluster."
else
  ISSUER="${KC_INTERNAL}/realms/${NAME}"
  JWKS_URL="${ISSUER}/protocol/openid-connect/certs"
  REALM_FILE="${REALMS_DIR}/${NAME}.json"
  if [ -e "$REALM_FILE" ]; then
    echo -e "  ${YELLOW}${REALM_FILE#"${REPO_DIR}/"} already exists — leaving it alone.${NC}"
  else
    cat > "$REALM_FILE" <<EOF
{
  "realm": "${NAME}",
  "displayName": "${DISPLAY}",
  "enabled": true,
  "sslRequired": "none",
  "accessTokenLifespan": 3600,
  "clients": [
    {
      "clientId": "${NAME}-agent",
      "name": "${DISPLAY} MCP Agent",
      "enabled": true,
      "publicClient": false,
      "secret": "${NAME}-secret",
      "serviceAccountsEnabled": true,
      "directAccessGrantsEnabled": true,
      "standardFlowEnabled": false,
      "protocolMappers": [
        {
          "name": "company",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-hardcoded-claim-mapper",
          "config": {
            "claim.name": "company",
            "claim.value": "${NAME}",
            "jsonType.label": "String",
            "access.token.claim": "true",
            "id.token.claim": "true",
            "userinfo.token.claim": "true"
          }
        },
        {
          "name": "tier",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-hardcoded-claim-mapper",
          "config": {
            "claim.name": "tier",
            "claim.value": "${TIER}",
            "jsonType.label": "String",
            "access.token.claim": "true",
            "id.token.claim": "true",
            "userinfo.token.claim": "true"
          }
        },
        {
          "name": "mcp-audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "config": {
            "included.custom.audience": "mcp-federation",
            "access.token.claim": "true",
            "id.token.claim": "false"
          }
        }
      ]
    }
  ]
}
EOF
    echo -e "  ${GREEN}✓${NC} wrote ${BOLD}${REALM_FILE#"${REPO_DIR}/"}${NC}  ${DIM}(new file — nothing else changed)${NC}"
  fi
fi

echo ""
echo -e "  Add this provider to ${BOLD}manifests/security/01-jwt-authentication.yaml${NC}"
echo -e "  ${DIM}under spec.traffic.jwtAuthentication.providers:${NC}"
echo ""
cat <<EOF
      - issuer: ${ISSUER}
        audiences: ["mcp-federation"]
        jwks:
          remote:
            url: ${JWKS_URL}
            cacheDuration: 5m
EOF

###############################################################################
# Step 2 — entitlements
###############################################################################
echo ""
echo -e "${BOLD}${CYAN}Step 2 — Entitlements${NC}"
echo ""
echo -e "  Add one line per server to each domain's policy. ${BOLD}Edit the tool lists${NC} —"
echo -e "  what is generated below is a read-only starting point, not a decision."
echo ""

emit_rule() {
  local file=$1 target=$2 tools=$3
  echo -e "  ${DIM}manifests/security/${file}${NC}"
  echo "          - 'jwt.company == \"${NAME}\" && mcp.tool.target == \"${target}\" && mcp.tool.name in [${tools}]'"
}

for d in ${DOMAINS//,/ }; do
  case "$d" in
    billing)
      emit_rule "02-authorization-billing.yaml" "payments"  '"get_payment", "list_payment_methods"'
      emit_rule "02-authorization-billing.yaml" "invoicing" '"get_invoice", "list_invoices"'
      ;;
    analytics)
      emit_rule "03-authorization-analytics.yaml" "reporting" '"get_kpi_summary", "list_reports"'
      emit_rule "03-authorization-analytics.yaml" "telemetry" '"list_event_types"'
      ;;
    support)
      emit_rule "04-authorization-support.yaml" "tickets" '"get_ticket", "search_tickets", "create_ticket"'
      ;;
  esac
  echo ""
done

for d in billing analytics support; do
  case ",$DOMAINS," in
    *",$d,"*) ;;
    *) echo -e "  ${DIM}no rule for /mcp/${d} — ${NAME} will authenticate, see zero tools, and be denied${NC}" ;;
  esac
done

###############################################################################
# Step 3 — quota
###############################################################################
echo ""
echo -e "${BOLD}${CYAN}Step 3 — Quota${NC}"
echo ""
if [ -n "$QUOTA" ]; then
  echo -e "  Add to ${BOLD}manifests/quotas/company-quotas.yaml${NC} under spec.raw.descriptors:"
  echo ""
  cat <<EOF
    - key: company
      value: ${NAME}
      rateLimit:
        requestsPerUnit: ${QUOTA}
        unit: MINUTE
EOF
else
  echo -e "  ${GREEN}✓${NC} Nothing to do — the catch-all descriptor already gives ${BOLD}${NAME}${NC} its own"
  echo -e "    per-company counter at the default rate. Add an explicit row only to"
  echo -e "    grant more than the default (re-run with ${DIM}--quota <n>${NC} to generate it)."
fi

###############################################################################
# Step 4 — billing
###############################################################################
echo ""
echo -e "${BOLD}${CYAN}Step 4 — Metering and chargeback${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Nothing to do. Metering labels every call with the ${BOLD}company${NC} claim, so"
echo -e "    ${NAME} appears in ${DIM}scripts/chargeback.py${NC} from its first request."

###############################################################################
# Apply
###############################################################################
echo ""
echo -e "${BOLD}${CYAN}Apply${NC}"
echo ""
if [ "$APPLY" = "true" ] && [ -z "$EXTERNAL_ISSUER" ]; then
  echo -e "  Rebuilding the realm ConfigMap and restarting Keycloak..."
  REALM_ARGS=()
  for realm in "${REALMS_DIR}"/*.json; do REALM_ARGS+=(--from-file="${realm}"); done
  kubectl create configmap keycloak-realms -n "$NS" "${REALM_ARGS[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -
  # Realms are imported at startup, so a new one needs a restart to appear.
  kubectl rollout restart deploy/keycloak -n "$NS"
  kubectl rollout status deploy/keycloak -n "$NS" --timeout=300s
  echo -e "  ${GREEN}✓${NC} realm '${NAME}' imported"
  echo ""
  echo -e "  Now make the two policy edits above, then:"
  echo -e "    ${DIM}kubectl apply -f manifests/security/ -f manifests/quotas/${NC}"
else
  echo -e "  1. make the edits printed above"
  echo -e "  2. rebuild the realm ConfigMap and restart Keycloak:"
  echo ""
  echo -e "     ${DIM}kubectl create configmap keycloak-realms -n ${NS} \\
       \$(for f in manifests/keycloak/realms/*.json; do echo --from-file=\$f; done) \\
       --dry-run=client -o yaml | kubectl apply -f -
     kubectl rollout restart deploy/keycloak -n ${NS}${NC}"
  echo ""
  echo -e "  3. ${DIM}kubectl apply -f manifests/security/ -f manifests/quotas/${NC}"
  echo -e "  ${DIM}(or re-run with --apply to do steps 2 automatically)${NC}"
fi

echo ""
echo -e "  Then verify:"
echo -e "    ${DIM}scripts/mcp.py token ${NAME}${NC}"
echo -e "    ${DIM}scripts/mcp.py matrix${NC}"
echo ""
echo -e "  ${YELLOW}▸${NC} Full runbook, including production IdP notes: ${BOLD}ONBOARDING.md${NC}"
echo ""
