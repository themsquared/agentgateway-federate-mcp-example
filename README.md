# Federated MCP on agentgateway

A working example of running **multiple MCP servers as a governed, multi-tenant
product**: federated into business domains, fronted by several OAuth providers,
with per-customer tool entitlements, per-customer quotas, and per-customer usage
metering for chargeback.

Three companies — **Acme**, **Globex**, **Initech** — each authenticate against
their own identity provider, connect to the same three URLs, and get three
completely different views of what they may do.

```
   Acme ─┐                                     ┌─ /mcp/billing    → payments, invoicing
 Globex ─┼─→ JWT ─→  agentgateway  ─→ federation ├─ /mcp/analytics  → reporting, telemetry
Initech ─┘           authn · authz            └─ /mcp/support    → tickets, crm
                     quota · metering
```

| | Acme (enterprise) | Globex (standard) | Initech (trial) |
| --- | --- | --- | --- |
| `/mcp/billing` | **8** tools | **4** read-only | **0** |
| `/mcp/analytics` | **8** | **9** *(+ data export add-on)* | **3** read-only |
| `/mcp/support` | **9** | **0** | **3** tickets only |
| Quota | 600/min | 60/min | 20/min |

Globex has *more* analytics tools than the enterprise account. Entitlements
follow commercial agreements, not a tier ladder — and the gateway expresses that
directly.

**The six MCP servers contain no authentication, authorization, quota, or billing
code.** Every one of those properties is added in front of them, declaratively,
in version control.

---

## Documentation

| | |
| --- | --- |
| **[WALKTHROUGH.md](WALKTHROUGH.md)** | Start to finish — how the whole thing is built, one layer at a time |
| **[ONBOARDING.md](ONBOARDING.md)** | Rinse and repeat — adding a new partner with their own IdP |
| **[PRODUCTION.md](PRODUCTION.md)** | Mapping the POC to a real estate — 50 IdPs, domain-based tenancy, opaque tokens, per-user quotas, many DCs |
| **[DEMO.md](DEMO.md)** | Presenter's guide and talk track for `./demo.sh` |

---

## Quick start

**Prerequisites:** `kubectl`, `helm`, `python3`, and either `k3d` (to create a
cluster) or an existing cluster. Plus a Solo agentgateway license key.

```bash
cp .env.example .env        # add your AGENTGATEWAY_LICENSE_KEY
./setup.sh                  # creates a k3d cluster and installs everything
```

Then, in a second terminal:

```bash
./port-forward.sh           # leave running: gateway :8080, Keycloak :8081, Prometheus :9090
```

And back in the first:

```bash
./demo.sh                   # guided six-act walkthrough
```

Other setup modes:

```bash
./setup.sh --use-current-context   # install into whatever kubectl points at
./setup.sh --skip-install          # re-apply manifests only (fast iteration)
./teardown.sh                      # remove the demo namespace
./teardown.sh --cluster            # delete the whole k3d cluster
```

---

## Explore it directly

```bash
scripts/mcp.py matrix
```

The entitlement matrix — every tool, every company, side by side. This is the
single most useful view in the repo.

```bash
scripts/mcp.py list acme billing                 # what one company can see
scripts/mcp.py token globex                      # the token and its claims

# an entitled call succeeds
scripts/mcp.py call globex analytics reporting_export_dataset '{"dataset":"fact_transactions"}'

# an unentitled call is not merely blocked — the tool is invisible
scripts/mcp.py call globex billing payments_create_charge '{"customer_id":"c","amount_cents":1}'

scripts/mcp.py quota initech 25                  # watch the quota engage
scripts/chargeback.py --by-tool                  # usage and cost by customer
scripts/chargeback.py --csv                      # same data for a billing pipeline
```

Onboard a fourth partner:

```bash
scripts/add-partner.sh --name umbrella --display "Umbrella Corp" \
  --tier standard --domains analytics,support
```

---

## How each capability works

### 1. Federation — six servers, three endpoints

`manifests/federation/backends.yaml`

An `AgentgatewayBackend` fans one MCP endpoint across several servers. Clients
connect once and see the union of the tools, namespaced `<server>_<tool>`.

- `prefixMode: Always` keeps tool names stable — the authorization rules depend on them.
- **Static targets, not selectors:** a selector derives its prefix from the
  discovered Service (`mcp-payments-8080_get_payment`); static targets keep the
  name you declared.
- `failureMode: FailOpen` — one target down does not fail the whole federation.

### 2. Authentication — three OAuth providers

`manifests/security/01-jwt-authentication.yaml`

One policy, three issuers. The gateway reads `iss`, picks the provider, and
verifies against *that* provider's JWKS. `mode: Strict` closes anonymous access;
`audiences` pins tokens to this gateway.

Each token carries `company` and `tier` claims — the two values everything else
keys off.

### 3. Authorization — per-company tool entitlements

`manifests/security/02-`, `03-`, `04-`

CEL expressions, OR'd, denied by default:

```yaml
- 'jwt.company == "globex" && mcp.tool.target == "payments" && mcp.tool.name in ["get_payment", "list_payment_methods"]'
```

Two things verified against a running gateway rather than assumed:

- `mcp.tool.name` is the **origin** tool name (`get_payment`), not the federated
  name the client sees (`payments_get_payment`).
- `mcp.tool.target` scopes a rule to one server — without it, a rule leaks to a
  same-named tool elsewhere in the federation.

Filtering applies to `tools/list` *and* `tools/call`; an unentitled call returns
`Unknown tool`, so a caller cannot confirm the tool exists.

### 4. Quotas — enforceable per company

`manifests/quotas/company-quotas.yaml`

A descriptor table keyed on `jwt.company`, backed by the Redis that ships with
the enterprise install, so limits hold **across all gateway replicas**. A
catch-all row gives any unlisted company its own counter at a default rate —
new partners are protected before anyone edits the file.

### 5. Metering — chargeback by customer

`manifests/observability/01-metering-attributes.yaml`

agentgateway already counts MCP calls by server and tool; this adds `company` and
`tier` labels from the validated JWT. Chargeback then becomes one query:

```promql
sum by (company, server, resource) (agentgateway_mcp_requests_total{method="tools/call"})
```

`scripts/chargeback.py` runs it, prices it from `scripts/pricing.json`, and also
reports allowed vs denied vs throttled per company.

---

## Repo map

```
setup.sh                  build everything
demo.sh                   six-act interactive walkthrough
port-forward.sh           gateway :8080, Keycloak :8081, Prometheus :9090
teardown.sh               remove it

mcp-server/server.py      the stub MCP server — stdlib only, all six run this file

manifests/
  00-namespace.yaml
  keycloak/
    keycloak.yaml         one Keycloak, three realms
    realms/*.json         one file per company — add a file to add a company
  mcp-servers/            six servers: tools + Deployment + Service each
  federation/
    backends.yaml         three virtual MCP servers
    gateway.yaml          the Gateway and its three routes
  security/
    01-jwt-authentication.yaml
    02-authorization-billing.yaml
    03-authorization-analytics.yaml
    04-authorization-support.yaml
  quotas/company-quotas.yaml
  observability/
    01-metering-attributes.yaml
    02-prometheus.yaml

scripts/
  mcp.py                  MCP client: list, call, matrix, quota, token
  chargeback.py           usage and cost report from Prometheus
  pricing.json            the rate card — edit freely
  add-partner.sh          onboard a new partner
```

---

## The stub MCP servers

All six run **one file** — `mcp-server/server.py`, Python standard library only —
on a stock `python:3.12-alpine` image. Everything server-specific (name, tools,
schemas, fake responses) comes from a JSON tool spec in a ConfigMap.

That means **no image to build and no registry to push to**. `setup.sh` publishes
`server.py` as a ConfigMap and the pods mount it. To change a tool, edit the JSON
in `manifests/mcp-servers/` and re-apply.

You can also run one locally:

```bash
TOOLS_FILE=<(kubectl get cm mcp-tools-payments -n mcp-federation -o jsonpath='{.data.tools\.json}') \
  python3 mcp-server/server.py
```

The tools return realistic, deterministic fake data — the same arguments always
produce the same invoice number, so a re-run of the demo looks identical.

---

## Notes and gotchas

**Keycloak's issuer is pinned.** `KC_HOSTNAME` is set to the in-cluster service
URL so tokens minted through `kubectl port-forward` still carry the in-cluster
`iss` and are accepted by the gateway. Without it, a token fetched from your
laptop would claim `iss=http://localhost:8081` and be rejected.

**Realms import at startup.** Adding a realm requires
`kubectl rollout restart deploy/keycloak -n mcp-federation`.

**Policies propagate through xDS.** Allow a few seconds after `kubectl apply`
before testing. `demo.sh` builds this in.

**Namespace discovery.** If agentgateway was already installed with
`discoveryNamespaceSelectors` — common when reusing a cluster that runs other
demos — its controller ignores namespaces that do not match, and the Gateway sits
at `Waiting for controller` with no obvious cause. `setup.sh` detects this and
labels the namespace automatically; if the selector uses `matchExpressions`
rather than `matchLabels` it warns instead, since that needs a human decision.
Its own install sets no selector.

**Quota units are HTTP requests,** not tool calls. One MCP session spends a few
(initialize, `tools/list`, then one per call), which is why the trial tier trips
after a handful of operations.

**Denied calls are still counted** in `agentgateway_mcp_requests_total` — it has
no status label. `scripts/chargeback.py` cross-references
`agentgateway_requests_total` (which does) to separate allowed from denied and
throttled. A production rate card would bill on successes only.

---

## Versions

Validated against:

| Component | Version |
| --- | --- |
| Solo Enterprise agentgateway | `v2026.8.0` |
| Gateway API | `v1.5.0` |
| Keycloak | `26.0` |
| Prometheus | `v3.1.0` |
| MCP protocol | `2025-06-18` |

Override any of them in `.env` (see `.env.example`).
