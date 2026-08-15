# Start to finish: how this is built

This is the whole system explained in the order it was assembled — six plain MCP
servers, then one capability at a time until they are a governed, metered,
multi-tenant product.

Every layer is added **at the gateway**, declaratively. Read the MCP servers in
`manifests/mcp-servers/` and you will not find a token, a permission check, a
rate limiter, or a line of billing code anywhere in them. That is the point.

```
                 ┌──────────┐   ┌──────────┐   ┌──────────┐
   companies →   │   Acme   │   │  Globex  │   │ Initech  │
                 │ realm/   │   │ realm/   │   │ realm/   │      ← 3 OAuth providers
                 │  IdP     │   │  IdP     │   │  IdP     │
                 └────┬─────┘   └────┬─────┘   └────┬─────┘
                      │  JWT         │  JWT         │  JWT
                      └──────────────┼──────────────┘
                                     ▼
                    ┌────────────────────────────────┐
                    │        agentgateway            │
                    │  ① authenticate  (3 issuers)   │
                    │  ② authorize     (per tool)    │
                    │  ③ quota         (per company) │
                    │  ④ meter         (per call)    │
                    └────────────────────────────────┘
                       /mcp/billing  /mcp/analytics  /mcp/support
                            │              │              │
                   ┌────────┴───┐   ┌──────┴─────┐   ┌────┴──────┐
                   │ payments   │   │ reporting  │   │ tickets   │
                   │ invoicing  │   │ telemetry  │   │ crm       │
                   └────────────┘   └────────────┘   └───────────┘
                            6 ordinary MCP servers
```

---

## Step 0 — The starting point: six unrelated MCP servers

Six MCP servers, owned by different teams, grouped into three business domains:

| Domain      | Servers                | Tools each |
| ----------- | ---------------------- | ---------- |
| `billing`   | `payments`, `invoicing` | 5 + 5      |
| `analytics` | `reporting`, `telemetry` | 5 + 5     |
| `support`   | `tickets`, `crm`        | 5 + 5      |

They are stubs returning realistic fake data, but they are real MCP servers
speaking Streamable HTTP. All six run the same file — `mcp-server/server.py`,
Python standard library only — and differ only in the tool spec mounted into
them. No image to build, no registry, no `pip install` at pod start.

**Problem:** a consumer needs six URLs, six connections, and six sets of
credentials — and gets no consistent way to control or measure any of it.

---

## Step 1 — Federation: six servers become three endpoints

`manifests/federation/backends.yaml`

An `AgentgatewayBackend` fans one MCP endpoint out across several servers. A
client connects **once** to `/mcp/billing` and sees the union of the payments and
invoicing tools, namespaced as `payments_get_payment`, `invoicing_get_invoice`.

```yaml
spec:
  mcp:
    failureMode: FailOpen     # one target down ≠ whole federation down
    prefixMode: Always        # tools are always <target>_<tool>
    targets:
    - name: payments
      static:
        host: mcp-payments.mcp-federation.svc.cluster.local
        port: 80
        path: /mcp
        protocol: StreamableHTTP
    - name: invoicing
      ...
```

Two decisions worth understanding:

- **`prefixMode: Always`** makes tool names stable and predictable. The
  authorization rules in Step 3 match on tool names; you do not want those
  names shifting under your policy.
- **Static targets, not label selectors.** A `selector:` target derives its
  prefix from the discovered Service, giving you
  `mcp-payments-8080_get_payment`. Static targets keep the `name:` you declared.
  Three extra lines buys you naming you control.

**Gained:** one endpoint per business domain. Adding a seventh server later is
an edit to this file — no consumer reconfiguration.
**Still missing:** anyone who can reach the endpoint can call anything.

---

## Step 2 — Authentication: who is calling?

`manifests/security/01-jwt-authentication.yaml`

One policy, three providers. agentgateway reads the token's `iss`, selects the
matching provider, and verifies the signature against **that** provider's JWKS.
Acme's realm cannot mint a token that passes as Globex.

```yaml
traffic:
  jwtAuthentication:
    mode: Strict                       # no token, no entry
    providers:
    - issuer: .../realms/acme
      audiences: ["mcp-federation"]    # pins the token to THIS gateway
      jwks:
        remote:
          url: .../realms/acme/protocol/openid-connect/certs
    - issuer: .../realms/globex
      ...
```

Each company authenticates against its own realm and receives a token carrying
two claims that drive everything downstream:

| claim     | drives                                      |
| --------- | ------------------------------------------- |
| `company` | tool entitlements, quota bucket, chargeback |
| `tier`    | quota tier, reporting                       |

> **Realms here are a stand-in.** In production each of these is the partner's
> own Okta, Entra, or Auth0 tenant. To the gateway a provider is an issuer URL
> and a JWKS URL — see [ONBOARDING.md](ONBOARDING.md).

**Gained:** anonymous access is closed; every request has a verified identity.
**Still missing:** authentication says *who you are*, not *what you may do*.
Right now Initech authenticates fine and still sees all ten billing tools.

---

## Step 3 — Authorization: what may they do?

`manifests/security/02-authorization-billing.yaml` (and `03-`, `04-`)

The entitlement contract, in git, reviewable in a pull request. One expression
per company per server; expressions are OR'd — allowed if any matches, **denied
if none do**.

```yaml
backend:
  mcp:
    authorization:
      action: Allow
      policy:
        matchExpressions:
        - 'jwt.company == "acme"   && mcp.tool.target == "payments"  && mcp.tool.name in ["get_payment", "list_payment_methods", "create_charge", "refund_payment"]'
        - 'jwt.company == "globex" && mcp.tool.target == "payments"  && mcp.tool.name in ["get_payment", "list_payment_methods"]'
        # Initech: no line at all → no billing access
```

**Two CEL details that are easy to get wrong** (both verified against a running
gateway, not inferred from docs):

- `mcp.tool.name` is the **origin** tool name — `get_payment`, *not* the
  federated `payments_get_payment` the client sees. The prefix is presentation;
  policy matches the real name.
- `mcp.tool.target` is the target name from the backend. You need it: without
  it, a rule allowing `get_invoice` would allow a same-named tool on any other
  server in the federation.

Enforcement runs in both directions. `tools/list` is filtered to what you may
use, and `tools/call` for anything else returns **`Unknown tool`** — a caller
cannot even confirm a tool it lacks rights to exists.

The resulting matrix (`scripts/mcp.py matrix`):

| Domain           | Acme | Globex | Initech |
| ---------------- | ---- | ------ | ------- |
| `/mcp/billing`   | 8    | 4      | 0       |
| `/mcp/analytics` | 8    | 9      | 3       |
| `/mcp/support`   | 9    | 0      | 3       |

Note **Globex has 9 analytics tools and Acme has 8** — Globex bought the bulk
data-export add-on and Acme did not. Entitlements follow commercial agreements,
not a tier ladder, and the policy expresses that directly.

Note also what *nobody* has: `payments.void_transaction`, `invoicing.void_invoice`,
`telemetry.purge_events`, `crm.delete_customer`. They are implemented and running.
The gateway is the only thing between "the capability exists" and "someone can
invoke it".

**Gained:** least-privilege per customer, denied by default.
**Still missing:** an entitled customer can still call its tools without limit.

---

## Step 4 — Quotas: how much may they do?

`manifests/quotas/company-quotas.yaml`

A descriptor table keyed on the same `company` claim, enforced **fleet-wide**
through the Redis that ships with the enterprise install.

```yaml
spec:
  raw:
    descriptors:
    - key: company
      value: acme
      rateLimit: { requestsPerUnit: 600, unit: MINUTE }
    - key: company
      value: initech
      rateLimit: { requestsPerUnit: 20, unit: MINUTE }
    - key: company                      # catch-all for anyone not listed
      rateLimit: { requestsPerUnit: 30, unit: MINUTE }
    rateLimits:
    - actions:
      - cel: { expression: 'jwt.company', key: company }
```

**Global, not local.** Counters are shared across every gateway replica, so
"20 per minute" means 20 in total — not 20 per replica. That is the difference
between a number you can put in a contract and one that silently multiplies by
your replica count. (`traffic.rateLimit.local` is the per-replica alternative:
no Redis needed, but it cannot make a fleet-wide promise.)

**The catch-all row matters for onboarding.** A descriptor with a key and no
value matches any value, so a partner added tomorrow is rate-limited from its
first request — under *its own* counter, not a shared one. Two partners on the
catch-all each get 30/min; they do not share a bucket. An explicit row is only
needed to grant *more* than the default.

**Gained:** one noisy tenant cannot spend another tenant's allowance, and
throttled traffic never reaches the MCP servers.
**Still missing:** you can control usage but not yet bill for it.

---

## Step 5 — Metering: what do we charge them?

`manifests/observability/01-metering-attributes.yaml`

agentgateway already counts MCP traffic — `agentgateway_mcp_requests_total`
carries `method`, `server`, `resource` (the tool) and `route` (the domain). What
it does not carry by default is **who called**. Without that you can see the
platform is busy but cannot bill anyone.

```yaml
frontend:
  metrics:
    attributes:
      add:
      - name: company
        expression: jwt.company
      - name: tier
        expression: jwt.tier
```

That is the entire change. Every counter is now broken out by paying customer,
and a chargeback report becomes one query:

```promql
sum by (company, server, resource) (
  agentgateway_mcp_requests_total{method="tools/call"}
)
```

`scripts/chargeback.py` runs exactly that, prices it from `scripts/pricing.json`,
and prints usage per customer × domain × server × tool, with a `--csv` mode for a
real billing pipeline.

> **Cardinality:** `company` and `tier` are safe labels — small, bounded value
> sets. Adding something like `jwt.sub` would multiply your series count by your
> user count. Meter on the billable entity, not the individual caller.

Two honest notes the report surfaces itself:

- `agentgateway_mcp_requests_total` has no status label, so it counts tool-call
  *attempts*, including ones authorization rejected. The report cross-references
  `agentgateway_requests_total` (which does carry `status`) to show allowed vs
  denied vs throttled per company. A production rate card would bill on
  successes only.
- The gateway is on the path for every call, so this is usage measured where a
  customer cannot under-report it — not self-reported by an agent.

**Gained:** defensible per-customer usage and cost attribution.

---

## Where that leaves you

| Capability     | Where it lives                       | Lines of app code |
| -------------- | ------------------------------------ | ----------------- |
| Federation     | `manifests/federation/`              | 0                 |
| Authentication | `manifests/security/01-`             | 0                 |
| Authorization  | `manifests/security/02- 03- 04-`     | 0                 |
| Quotas         | `manifests/quotas/`                  | 0                 |
| Metering       | `manifests/observability/01-`        | 0                 |

The six MCP servers were never modified. Every property a multi-tenant product
needs was added in front of them, as configuration, in version control.

Onboarding the next partner is therefore a bounded change to three files and
nothing else — which is what [ONBOARDING.md](ONBOARDING.md) covers.

---

## Try it yourself

```bash
./demo.sh              # the same arc, live and interactive
./demo.sh --act 3      # jump straight to authorization

scripts/mcp.py matrix
scripts/mcp.py list globex analytics
scripts/mcp.py call globex billing payments_create_charge '{"customer_id":"c","amount_cents":1}'
scripts/mcp.py quota initech 25
scripts/chargeback.py --by-tool
```
