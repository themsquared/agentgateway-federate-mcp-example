# Onboarding a new partner

The repeatable runbook for adding an external partner or customer to the
federation — with their own identity provider, their own entitlements, their own
quota, and their own line on the chargeback report.

**Onboarding is a policy change, not a deployment.** No new endpoints, no new MCP
servers, no restarts of anything an existing customer touches, and nothing at all
to do for billing.

---

## The shape of it

Everything in this platform keys off **two claims on a token**:

| claim     | drives                                      |
| --------- | ------------------------------------------- |
| `company` | tool entitlements, quota bucket, chargeback |
| `tier`    | quota tier, reporting                       |

So onboarding is: make the gateway trust their IdP, make sure that IdP emits
those two claims, and write down what they bought.

| # | Step           | Where                                        | Effort            |
| - | -------------- | -------------------------------------------- | ----------------- |
| 1 | Trust their IdP | `manifests/security/01-jwt-authentication.yaml` | one block      |
| 2 | Entitlements   | `manifests/security/02- 03- 04-`              | one line/domain   |
| 3 | Quota          | `manifests/quotas/company-quotas.yaml`        | optional          |
| 4 | Billing        | —                                             | **nothing**       |

Steps 1–3 are a single reviewable pull request. That PR *is* the commercial
agreement, expressed as configuration.

---

## Quick start

```bash
scripts/add-partner.sh \
  --name umbrella \
  --display "Umbrella Corp" \
  --tier standard \
  --domains analytics,support
```

The script creates the identity provider and prints the exact YAML to paste for
the rest. It deliberately **does not** edit the entitlement policies for you:
what a customer is allowed to call is a commercial decision and belongs in a
reviewed diff, not in a generator's output.

Add `--apply` to also rebuild the realm ConfigMap and restart Keycloak.

---

## Step 1 — Make the gateway trust their identity provider

You have two options, and the demo ships the first only because it is
self-contained. **In production you almost always want the second.**

### Option A — a realm here (demo / proof-of-concept)

`scripts/add-partner.sh` writes `manifests/keycloak/realms/<name>.json`. Adding a
company adds a file; no existing realm is touched.

```bash
# rebuild the ConfigMap from every realm file and restart Keycloak
kubectl create configmap keycloak-realms -n mcp-federation \
  $(for f in manifests/keycloak/realms/*.json; do echo --from-file=$f; done) \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/keycloak -n mcp-federation
```

> Realms are imported at **startup**, so a new realm needs that restart.

### Option B — the partner's own IdP (production)

The partner keeps their own Okta, Entra, Auth0, Descope, or Authentik tenant, and
you never hold their user directory or credentials. To agentgateway a provider is
just an issuer URL and a JWKS URL:

```bash
scripts/add-partner.sh --name umbrella --display "Umbrella Corp" \
  --tier standard --domains analytics,support \
  --external-issuer https://umbrella.okta.com/oauth2/default
```

Either way, add the printed block to
`manifests/security/01-jwt-authentication.yaml` under
`spec.traffic.jwtAuthentication.providers`:

```yaml
      - issuer: https://umbrella.okta.com/oauth2/default
        audiences: ["mcp-federation"]
        jwks:
          remote:
            url: https://umbrella.okta.com/oauth2/default/v1/keys
            cacheDuration: 5m
```

**What to ask the partner for:**

1. Their **issuer URL** (must match the `iss` claim exactly — a trailing slash
   mismatch is the single most common failure).
2. Their **JWKS URL**, reachable *from inside your cluster*. If their IdP is
   internet-facing this is usually free; if not, you need egress or a mirror.
3. A **`company` claim** on the access token whose value is the `--name` you
   chose, and a **`tier` claim**.
4. `mcp-federation` in the token's **audience**.

**How partners usually emit those claims:**

| IdP      | Mechanism                                                        |
| -------- | ---------------------------------------------------------------- |
| Okta     | Custom claim on the authorization server, or a claim from a group |
| Entra ID | Optional claims, or an app role mapped to the value               |
| Auth0    | An Action adding a namespaced custom claim                        |
| Keycloak | Protocol mapper (hardcoded, attribute, or group membership)       |

> **If the partner cannot add custom claims**, you have two fallbacks. Either
> derive company from the issuer itself — `jwt.iss == "https://umbrella.okta.com/oauth2/default"`
> works anywhere `jwt.company` does, in both entitlement rules and the quota CEL —
> or match on OAuth scopes: `"reporting:read" in jwt.scope.split(" ")`. Both
> forms are validated against a live gateway. Deriving from `iss` is the most
> robust: it needs nothing from the partner beyond an OIDC endpoint.
>
> **If the partner's auth server issues opaque (non-JWT) tokens**, JWKS
> validation cannot check them at all — that requires calling the auth server's
> introspection endpoint via `extAuth`, which this POC does not demonstrate.
> See [PRODUCTION.md](PRODUCTION.md) before promising it.

---

## Step 2 — Write down what they bought

One line per server, in the policy for each domain they have access to. Start
from what `add-partner.sh` printed and **edit the tool lists** to match the
contract.

```yaml
# manifests/security/03-authorization-analytics.yaml
          - 'jwt.company == "umbrella" && mcp.tool.target == "reporting" && mcp.tool.name in ["get_kpi_summary", "list_reports"]'
          - 'jwt.company == "umbrella" && mcp.tool.target == "telemetry" && mcp.tool.name in ["list_event_types"]'
```

Rules for getting this right:

- **Domains they did not buy get no line.** Absence is the denial — you never
  write a deny rule. They will authenticate, reach the endpoint, and see zero
  tools.
- **`mcp.tool.name` is the origin tool name** (`get_kpi_summary`), not the
  federated name the client sees (`reporting_get_kpi_summary`).
- **Always include `mcp.tool.target`.** Without it a rule leaks to a same-named
  tool on another server in the federation.
- **Grant read-only first.** It is far easier to add `create_charge` next quarter
  than to explain why a partner could call it this quarter.

---

## Step 3 — Quota (usually nothing to do)

The catch-all descriptor in `manifests/quotas/company-quotas.yaml` already gives
any unlisted company **its own** per-company counter at the default rate. A new
partner is rate-limited from its first request without anyone remembering to edit
the file.

Only add an explicit row to grant *more* than the default:

```yaml
    - key: company
      value: umbrella
      rateLimit:
        requestsPerUnit: 120
        unit: MINUTE
```

> Two partners on the catch-all do **not** share a bucket — they each get the
> default independently. The catch-all sets the *limit*, not the *key*.

---

## Step 4 — Billing

Nothing. Metering labels every call with the `company` claim, so the new partner
appears in `scripts/chargeback.py` from its first request, priced by the same
`scripts/pricing.json` rate card.

If they negotiated custom rates, that is a per-customer price book — extend
`pricing.json` or map `company` to a rate table in your billing system. The
metric grain (customer × domain × server × tool) already supports it.

---

## Step 5 — Apply and verify

```bash
kubectl apply -f manifests/security/ -f manifests/quotas/
```

Then confirm — ideally with the partner on the call:

```bash
export COMPANIES=acme,globex,initech,umbrella

scripts/mcp.py token umbrella      # correct iss, company and tier claims?
scripts/mcp.py matrix              # exactly the tools they bought, nothing more
scripts/mcp.py list umbrella billing   # a domain they did NOT buy → 0 tools
```

**Acceptance checklist:**

- [ ] Token shows the expected `company`, `tier`, and `aud`
- [ ] Every domain they bought lists exactly the agreed tools
- [ ] Every domain they did **not** buy lists zero tools
- [ ] A write tool they did not buy returns `Unknown tool`, not a result
- [ ] `scripts/mcp.py quota umbrella 40` throttles at the expected point
- [ ] They appear in `scripts/chargeback.py` after generating traffic
- [ ] No existing company's row in `scripts/mcp.py matrix` changed

That last one is the regression test that matters. Run `scripts/mcp.py matrix`
before and after and diff it: onboarding a partner must not alter anyone else's
access.

---

## Offboarding

Remove their lines from the entitlement policies and apply. They immediately see
zero tools everywhere while their tokens still validate — the cleanest state for
a suspension, and trivially reversible.

To cut them off entirely, also remove their provider block from
`01-jwt-authentication.yaml`; their tokens then fail at authentication with a
401. Delete the realm file (Option A) or revoke the client at their IdP
(Option B) last.

Historical metrics keep their `company` label, so past usage stays billable and
auditable after access is removed.

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `401 authentication failure: no bearer token found` | No `Authorization: Bearer` header. |
| `401` with a token that looks fine | `iss` does not exactly match a configured provider (trailing slash), or `mcp-federation` is missing from `aud`. |
| Token validates but **every** domain shows 0 tools | No entitlement lines matched — check the `company` claim value equals the string in your rules. |
| A tool is missing from one domain only | The rule matched a different `mcp.tool.target`, or used the federated name (`reporting_run_report`) instead of the origin name (`run_report`). |
| Gateway cannot fetch JWKS | The JWKS URL is not resolvable from inside the cluster. Check egress; `kubectl run -it --rm curl --image=curlimages/curl -- curl <jwks-url>`. |
| Policy edited but nothing changed | Policies reach the proxy through xDS — allow a few seconds, then check `kubectl get agentgatewaypolicy -n mcp-federation -o yaml` for an `Accepted` condition. |
| New realm returns 404 | Realms import at startup: `kubectl rollout restart deploy/keycloak -n mcp-federation`. |
