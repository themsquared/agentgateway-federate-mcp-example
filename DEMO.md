# Presenter's guide

Talk track for `./demo.sh`. Six acts, roughly 20–30 minutes depending on how much
the room interrupts — and you want them interrupting.

For the architecture in prose, see [WALKTHROUGH.md](WALKTHROUGH.md). For adding a
customer, [ONBOARDING.md](ONBOARDING.md).

---

## Before you start

```bash
./setup.sh                  # once, ahead of time — takes several minutes
./port-forward.sh           # second terminal, leave running
./demo.sh                   # first terminal
```

`demo.sh` starts by removing the authn, authz, quota and metering policies, then
re-applies each one from its real manifest as you walk through. The audience sees
the platform actually change, not a slideshow of YAML.

Useful controls:

```bash
./demo.sh --act 3     # reset, fast-forward acts 1-2 silently, play act 3 live
./demo.sh --reset     # put everything back to fully-configured and exit
```

Run `./demo.sh --reset` after any partial run so the environment is consistent
for the next one.

**Pre-flight, five minutes before:** `scripts/mcp.py matrix` should print a full
table. If it errors, your port-forwards dropped — restart `./port-forward.sh`.

---

## The one-sentence framing

> Six MCP servers your teams already built, turned into a product you can sell to
> three different customers — without touching any of the six.

If someone only remembers one thing, make it that the MCP servers were never
modified.

---

## Act 1 — Federation

**Claim:** consumers should ask for a *business capability*, not a list of
services.

Show the six deployments, then the `AgentgatewayBackend`. The key move is
`scripts/mcp.py list acme billing` — ten tools from two different servers over
**one** connection, namespaced `payments_*` and `invoicing_*`.

Worth saying out loud:

- Adding a seventh billing service later is an edit to one file. No consumer
  reconfigures anything, and no new endpoint gets published.
- `failureMode: FailOpen` — one server down degrades the federation instead of
  breaking it.

**End on the problem:** there is no authentication yet. Anyone who can reach this
endpoint can call anything, including `void_transaction`. That sets up Act 2.

> **If asked "why static targets instead of label selectors?"** — selectors derive
> the tool prefix from the discovered Service, so you get
> `mcp-payments-8080_get_payment`. The authorization rules in Act 3 match on tool
> names; you do not want those names moving. Three extra lines buys naming you
> control.

---

## Act 2 — Authentication

**Claim:** every customer brings their own identity provider, and you should not
be running a user directory on their behalf.

`scripts/mcp.py token acme` shows the token. Point at the two claims — `company`
and `tier` — and say plainly: *everything in the next three acts is driven by
these two values.*

Then apply the policy and show the 401. Then show that a valid Initech token gets
in — **and still sees all ten billing tools.**

That last beat is the point of the act: authentication tells you *who*, not
*what*. Do not skip it; it makes Act 3 land.

> **Expect this question: "do all our customers have to use Keycloak?"** No. The
> gateway needs an issuer URL and a JWKS URL. The three realms here are a
> self-contained stand-in; in production each is the partner's own Okta, Entra, or
> Auth0 tenant. `manifests/security/01-jwt-authentication.yaml` is a list of
> providers — they can be anything, and they can be different from each other.

---

## Act 3 — Authorization

**This is the act that sells the product.** Give it the most time.

Show the billing policy first. Read one expression aloud — it is deliberately
legible to a non-engineer:

```
jwt.company == "globex" && mcp.tool.target == "payments" && mcp.tool.name in ["get_payment", "list_payment_methods"]
```

Then apply all three domains and run `scripts/mcp.py matrix`.

Let the table sit on screen. The three things to draw out:

1. **Initech sees zero billing tools.** Not an error — an empty list. They never
   learn billing exists.
2. **Globex has 9 analytics tools; Acme has 8.** The enterprise account has
   *fewer*. Globex bought the data-export add-on. Entitlements follow contracts,
   not a tier ladder — and the policy says so directly, with no tier hierarchy to
   model around.
3. **Nobody can reach `void_transaction`, `void_invoice`, `purge_events`, or
   `delete_customer`.** They are implemented and running on the servers right
   now. The gateway is the only thing making them unreachable.

Then the denied call. Note the error is **`Unknown tool`**, not "forbidden" —
Globex cannot even confirm the capability exists. Enumeration is not a risk when
there is nothing to enumerate.

> **Expect: "where does this policy live?"** In git, applied by CI, reviewable in
> a pull request. The PR *is* the commercial agreement, expressed as config.

> **Expect: "what if the IdP should own entitlements?"** It can — swap
> `jwt.company == "globex"` for a scope check: `"billing:write" in jwt.scope.split(" ")`
> (validated on this stack). The same CEL reads either. This demo puts policy in
> the gateway because platform teams usually want the contract in their own
> repo, but nothing forces that.

---

## Act 4 — Quotas

**Claim:** a limit that multiplies by your replica count is not a limit you can
put in a contract.

Show the descriptor table, apply it, then `scripts/mcp.py quota initech 25` —
watch 429s appear at 20. Follow with `scripts/mcp.py quota acme 8`: unaffected.

Points to land:

- Counters are in shared Redis, so the limit holds **across every gateway
  replica**. `local` rate limiting is per-replica and cannot make that promise.
- Throttled traffic **never reaches the MCP servers** — you are protecting the
  backends, not just billing for the abuse.
- The catch-all row means a partner onboarded tomorrow is limited from its first
  request, under its own counter, before anyone edits this file.

> **Note honestly:** the unit is HTTP requests, not tool calls. An MCP session
> spends a few. If someone wants per-tool cost weighting, the descriptor supports
> a `cost` expression — say so rather than hand-waving.

---

## Act 5 — Metering and chargeback

**Claim:** the gateway is the only place usage can be counted in a way the
customer cannot under-report.

Show that the policy is *four lines* — two labels lifted off the validated JWT.
Then the traffic burst, then `scripts/chargeback.py --by-tool`.

What to point at:

- Every number comes from **one PromQL query**. No MCP server knows about
  billing; no agent self-reports usage.
- The grain is customer × domain × server × tool. That is what a rate card needs.
- **Globex's bill is dominated by dataset exports** — the add-on they bought in
  Act 3 is the line item they pay for in Act 5. Same claim, all the way through.
- The `(unattributed)` block is real: it is the traffic from Acts 2–4, before the
  metering policy existed. Use it — it shows the labels are genuinely applied at
  request time, not backfilled.
- The enforcement table separates allowed from denied and throttled. Denied
  attempts appear in the tool counters (that metric has no status label), so a
  production rate card bills on successes only. Say this before they find it.

Finish with `--csv` — this is the shape that goes into a billing pipeline.

> **Expect: "can we bill on tokens or data volume instead of calls?"** The same
> labels land on `agentgateway_requests_total` and `agentgateway_response_bytes_total`,
> so bytes are available now. Token-based metering is the LLM path, which this
> demo does not cover.

> **Expect: "what about cardinality?"** `company` and `tier` are bounded — one
> value per customer, one per plan. Adding `jwt.sub` would multiply series by user
> count. Meter on the billable entity, not the caller.

---

## Act 6 — Onboarding

**Claim:** the fourth customer is a pull request, not a project.

Walk the four steps, then show `scripts/add-partner.sh --help`. The punchline is
step 4: billing needs **nothing**, because metering keys off the same claim that
authorization and quotas already use.

If you have time and the room is technical, actually run it:

```bash
scripts/add-partner.sh --name umbrella --display "Umbrella Corp" \
  --tier standard --domains analytics,support --apply
```

Then make the two printed edits, `kubectl apply -f manifests/security/`, and run
`scripts/mcp.py matrix` with `COMPANIES=acme,globex,initech,umbrella`. A fourth
column appears with exactly the tools you granted. End-to-end in about two
minutes.

The regression test worth naming: run `scripts/mcp.py matrix` before and after
and diff. **Onboarding a partner must not change anyone else's access.**

---

## Questions that come up

**"Is this production-ready or a toy?"** The gateway configuration is production
shape — the same CRDs, policies and enforcement path you would run. What is
demo-grade: the six MCP servers are stubs, Keycloak runs in dev mode with
hardcoded client secrets, Prometheus has no persistence, and the quotas are tiny
so they can be tripped on stage.

**"What happens when the gateway is down?"** Same answer as any gateway: run
replicas. Quota counters are in shared Redis precisely so replicas agree.

**"Can an agent bypass the gateway and hit the MCP servers directly?"** In this
demo the Services are reachable inside the cluster, so yes — network policy or a
service mesh is what stops that, and it is the right tool for it. The gateway
enforces the contract; the network enforces the path.

**"How do we handle a partner whose IdP can't add custom claims?"** Derive the
company from the issuer instead — `jwt.iss == "https://umbrella.okta.com/oauth2/default"`
works anywhere `jwt.company` does, including the quota expression. It needs
nothing from the partner beyond an OIDC endpoint.

**"Does this work with real MCP servers, not stubs?"** Yes — the federation
targets any Streamable HTTP or SSE MCP server. Swap the `static:` host and port
in `manifests/federation/backends.yaml`; nothing else changes.

---

## If something breaks mid-demo

| Symptom | Fix |
| --- | --- |
| Connection refused from any script | A port-forward dropped. Restart `./port-forward.sh`. |
| Policy applied but behaviour unchanged | xDS propagation — wait a few seconds and re-run. |
| Unexpected 429s | You are inside a previous act's quota window. Wait a minute. |
| Matrix shows a partial table | Same — the trial tier ran out mid-read. It prints a note saying so. |
| Everything looks wrong | `./demo.sh --reset`, then re-run from the act you need. |
