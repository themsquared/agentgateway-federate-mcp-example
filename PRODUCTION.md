# From POC to production: mapping this to a real multi-customer estate

This demo uses three companies and one Keycloak so it can run on a laptop. A real
deployment looks more like: **dozens of customers, each with their own auth
server**, running across **many clusters/data centers**, onboarded by an
automated pipeline rather than a human editing YAML.

This page maps each POC decision to that reality — including the places where
the production answer is *different* from what the demo does, and the one
capability this POC deliberately does not demonstrate.

---

## Identifying the customer: issuer, domain, or header

The historical pattern for multi-tenant platforms is **domain-based**: each
customer gets `customerA.example.com`, and the platform infers the tenant from
the hostname, then has to look up which auth server that tenant uses.

This POC uses a different and simpler mechanism: **the token itself says who the
customer is.** The gateway's JWT policy lists one provider per customer; on each
request it reads the token's `iss` claim, picks the matching provider, and
validates against *that* provider's keys. The "which auth server does this
customer use" lookup table is the policy — there is no separate mapping to
maintain, and one endpoint serves every tenant.

Both models work on agentgateway, and they compose:

| Model | How | When to prefer it |
| --- | --- | --- |
| **Issuer-based** (this POC) | multi-provider `jwtAuthentication`; tenant = validated claim | Machine/agent traffic with bearer tokens — the MCP case |
| **Domain-based** | per-customer `hostnames:` on HTTPRoutes (or listeners); attach per-host policy | You already route `customerA.example.com` and want the gateway to mirror it |
| **Header-based** | CEL over headers in authorization/rate-limit expressions | An upstream proxy already stamps a trusted tenant header |

A practical hybrid: keep per-customer hostnames for routing continuity, and
still make every *security* decision from the validated token, never from the
hostname — a hostname is caller-controlled, a validated claim is not.

---

## Scaling from 3 identity providers to 50

Nothing in the data path changes: the `providers:` list in
[manifests/security/01-jwt-authentication.yaml](manifests/security/01-jwt-authentication.yaml)
grows to 50 entries, one per customer auth server. What changes is who writes
the entry.

At that scale, no human should be editing these files. The intended shape — and
the reason everything in this repo is a CRD:

1. A front end (Backstage, Cortex, an internal admin app) captures "new
   customer" as a form: name, tier, issuer URL, purchased domains.
2. A pipeline renders the three artifacts `scripts/add-partner.sh` generates
   today — provider block, entitlement lines, optional quota row — and opens a
   pull request.
3. Review + merge = onboarded. GitOps applies the CRDs; no deployment, no
   restart of anything another customer touches.

`add-partner.sh` is the seed of step 2 written as a shell script — the logic a
pipeline would own. The catch-all quota row and deny-by-default authorization
mean a half-onboarded customer fails safe at every stage.

**Offboarding is the same change in reverse**, and historical metrics keep the
`company` label after access is removed, so past usage stays billable.

---

## Opaque tokens and introspection — the one honest gap

This POC validates **JWTs against each provider's JWKS**. That is the
right-sized mechanism when customer auth servers issue JWT access tokens (most
modern Okta/Entra/Auth0/Keycloak setups do).

Some customer auth servers issue **opaque tokens** that can only be checked by
calling the auth server's **introspection endpoint** (RFC 7662). JWKS
validation cannot handle those. On agentgateway that becomes an **external
authorization** step (`traffic.extAuth`) calling an introspection service —
either per customer or a small broker that fans out by tenant — with the
introspection result's claims then driving the same entitlement CEL.

**This repo does not demonstrate introspection.** If any real customer auth
server is opaque-token-only, say so during the POC and it becomes a test case —
the policy surface exists (`extAuth`), but the claim it needs validating in
*your* environment, not assuming.

Related fallbacks that *are* validated here, for partners whose IdP cannot emit
custom claims:

- **Derive the tenant from the issuer**: `jwt.iss == "https://partner.okta.com/oauth2/default"`
  works everywhere `jwt.company` does — entitlements and quota CEL alike.
  Verified against a live gateway.
- **Match on scopes instead of custom claims**: if the auth server expresses
  entitlements as OAuth scopes, the CEL reads the standard space-delimited
  `scope` string directly. Both of these are verified against a live gateway;
  prefer the `split` form — `contains()` is substring matching, and
  `"reporting:read"` would also match a hypothetical `xreporting:readonly`:

  ```yaml
  - '"reporting:read" in jwt.scope.split(" ") && mcp.tool.target == "reporting"'   # exact scope token
  - 'jwt.scope.contains("reporting:read") && mcp.tool.target == "reporting"'       # substring — looser
  ```

---

## Quotas: per customer, and per user within a customer

The POC enforces **per-company** quotas. The scoping conversation also asked for
"an amount of usage per client, *or per user in a client*." That is a nested
descriptor, and it is **validated working** on this stack — a service account
and a named user in the same company each got their own counter:

```yaml
# Tested against agentgateway v2026.8.0 + the bundled rate limiter.
# Composes with company-quotas.yaml: attach both configs to the same policy via
# a second entry in rateLimitConfigRefs. A request is throttled if EITHER limit
# is exhausted (the company ceiling still caps the tenant as a whole).
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: per-user-quotas
  namespace: mcp-federation
spec:
  raw:
    descriptors:
    - key: company
      value: globex
      descriptors:            # nested: a bucket per user WITHIN globex
      - key: user
        rateLimit:
          requestsPerUnit: 60
          unit: MINUTE
    rateLimits:
    - actions:
      - cel: { expression: 'jwt.company', key: company }
      - cel: { expression: 'jwt.sub',     key: user }
```

Cardinality caution: `jwt.sub` is fine as a **rate-limit key** (Redis handles
per-user counters happily) but do **not** add it as a *metric label* — that
multiplies your Prometheus series by your user count. Meter per company; limit
per user.

---

## Policy attaches at three layers — and who owns each

Every policy in this repo targets one of three attachment points, and the split
is an ownership model, not an accident:

| Layer | Owner | In this repo |
| --- | --- | --- |
| **Gateway** — applies to all traffic; the platform's red lines | Platform team | JWT authn, company quotas, metering labels |
| **Route** — one federated domain | Domain/product team | (none yet — e.g. a stricter timeout on `/mcp/analytics`) |
| **Backend** — one federation's tools | The team that owns those MCP servers | The three entitlement policies |

The entitlement policies sit at the **backend** deliberately: the team that owns
the billing servers owns who may call billing tools, without being able to
loosen the platform-wide authentication above them. In a 50-customer, many-team
setup this is what keeps the policy repo from becoming a single team's
bottleneck.

---

## Many data centers

The whole configuration is declarative, so "deploy to 15 data centers" is the
same manifests applied per cluster through GitOps — the same argument as
onboarding, applied to geography. Two honest footnotes:

- **Quota counters are per-install.** Each cluster's rate limiter uses its own
  Redis, so "600/min" enforced in 15 data centers is 600/min *per DC*, not
  globally. If a customer's contract number must be global across DCs, that
  needs a shared/centralized counter store — a design conversation, not a YAML
  edit. (Within one cluster, counters are already shared across all gateway
  replicas.)
- **Metering aggregates cleanly.** Prometheus per cluster, one `cluster` label
  added at scrape/remote-write time, and the chargeback query sums across DCs
  without modification.

## Air-gapped / restricted-egress environments

Everything runs in-cluster and phones home to nothing. To run without internet
egress, mirror these into your registry and override the image references:

- `python:3.12-alpine` (the six stub servers)
- `quay.io/keycloak/keycloak:26.0`
- `quay.io/prometheus/prometheus:v3.1.0`
- the Solo images pulled by the `enterprise-agentgateway` chart from
  `us-docker.pkg.dev/solo-public/...` (chart + proxy + rate limiter + Redis)

The Gateway API CRDs (`standard-install.yaml`) and the Helm charts are the only
install-time downloads in `setup.sh`; both can be vendored.

---

## What this POC deliberately does not cover

So the evaluation sheet is honest:

- **Token introspection / opaque tokens** — policy surface exists (`extAuth`),
  not demonstrated here. See above.
- **LLM front-ending** (model routing, PII guardrails, token-based cost
  controls) — agentgateway does this, but this repo scopes to the MCP
  federation story.
- **Monetization as billing** — the gateway meters (counts, attributes,
  exposes); `scripts/chargeback.py` + `pricing.json` show the rate-card shape.
  Invoicing, plans, and volume discounts belong in your billing system,
  consuming the `--csv` output or the metrics directly.
- **Network-level bypass protection** — in the demo the MCP Services are
  reachable in-cluster. Production wants NetworkPolicy or a mesh so the gateway
  is the only path. The gateway enforces the contract; the network enforces the
  path.
