#!/usr/bin/env python3
"""
Chargeback report — who used what, and what it costs.

Every number here comes from one Prometheus query against a metric agentgateway
emits on its own. Nothing in the MCP servers knows about billing, and no agent
reports its own usage: the gateway is on the path for every call, so it is the
one place where usage can be counted in a way a customer cannot under-report.

The query is:

  sum by (company, tier, route, server, resource) (
    agentgateway_mcp_requests_total{method="tools/call"}
  )

  company/tier  added by manifests/observability/01-metering-attributes.yaml
                from the caller's validated JWT
  route         the federated domain (mcp-billing / mcp-analytics / mcp-support)
  server        which MCP server behind the federation actually served the call
  resource      which tool was invoked

That breakdown is exactly the grain a chargeback needs: customer × product ×
operation. Rates come from pricing.json.

Usage:
  chargeback.py                 report from the raw counters (since gateway start)
  chargeback.py --window 15m    report over a trailing window instead
  chargeback.py --by-tool       add the per-tool detail lines
  chargeback.py --csv           machine-readable output for a billing pipeline

Env:
  PROMETHEUS_URL   default http://localhost:9090
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://localhost:9090").rstrip("/")
PRICING_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pricing.json")

BOLD = "\033[1m"
DIM = "\033[2m"
GREEN = "\033[0;32m"
CYAN = "\033[0;36m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
NC = "\033[0m"

DOMAIN_OF = {
    "mcp-billing": "billing",
    "mcp-analytics": "analytics",
    "mcp-support": "support",
}


def load_pricing():
    with open(PRICING_FILE) as fh:
        spec = json.load(fh)
    return spec.get("default", 0.0), spec.get("overrides", {})


def query(promql):
    url = f"{PROMETHEUS_URL}/api/v1/query?" + urllib.parse.urlencode({"query": promql})
    try:
        with urllib.request.urlopen(url, timeout=20) as resp:
            body = json.load(resp)
    except urllib.error.URLError as exc:
        print(f"{RED}error:{NC} could not reach Prometheus at {PROMETHEUS_URL} ({exc})\n"
              f"       Is ./port-forward.sh running?", file=sys.stderr)
        sys.exit(1)
    if body.get("status") != "success":
        print(f"{RED}error:{NC} query failed: {body}", file=sys.stderr)
        sys.exit(1)
    return body["data"]["result"]


def collect(window):
    metric = 'agentgateway_mcp_requests_total{method="tools/call"}'
    # Raw counters are exact and easy to explain. increase() over a window is the
    # right tool for a trailing report and copes with counter resets, at the cost
    # of Prometheus extrapolating at the window edges.
    inner = f"increase({metric}[{window}])" if window else metric
    promql = f"sum by (company, tier, route, server, resource) ({inner})"

    rows = []
    for series in query(promql):
        labels = series["metric"]
        calls = float(series["value"][1])
        if calls < 0.5:
            continue
        route = labels.get("route", "").split("/")[-1]
        rows.append({
            "company": labels.get("company") or "(unattributed)",
            "tier": labels.get("tier") or "-",
            "domain": DOMAIN_OF.get(route, route or "-"),
            "server": labels.get("server", "-"),
            "tool": labels.get("resource", "-"),
            "calls": int(round(calls)),
        })
    return rows


def collect_enforcement(window):
    """Per-company HTTP outcomes, for the governance half of the picture.

    agentgateway_mcp_requests_total counts tool-call ATTEMPTS and carries no
    status label, so a call the authorization policy rejected is counted there
    alongside one that succeeded. agentgateway_requests_total does carry status
    (but not the tool name), so the two together give both "what did they use"
    and "what did we stop".
    """
    metric = 'agentgateway_requests_total{protocol="mcp"}'
    inner = f"increase({metric}[{window}])" if window else metric
    out = {}
    for series in query(f"sum by (company, status) ({inner})"):
        company = series["metric"].get("company") or "(unattributed)"
        status = series["metric"].get("status", "?")
        count = float(series["value"][1])
        if count < 0.5:
            continue
        out.setdefault(company, {})[status] = out.setdefault(company, {}).get(status, 0) + int(round(count))
    return out


def price_rows(rows):
    default, overrides = load_pricing()
    for row in rows:
        rate = overrides.get(f"{row['server']}.{row['tool']}", default)
        row["rate"] = rate
        row["amount"] = rate * row["calls"]
    return rows


def print_csv(rows):
    print("company,tier,domain,server,tool,calls,unit_usd,amount_usd")
    for r in sorted(rows, key=lambda r: (r["company"], r["domain"], r["server"], r["tool"])):
        print(f"{r['company']},{r['tier']},{r['domain']},{r['server']},{r['tool']},"
              f"{r['calls']},{r['rate']:.4f},{r['amount']:.4f}")


def print_enforcement(enforcement):
    if not enforcement:
        return
    print(f"{BOLD}Policy enforcement{NC} {DIM}(agentgateway_requests_total by status){NC}\n")
    print(f"  {DIM}{'company':<16}{'allowed':>9}{'denied':>9}{'throttled':>11}{'unauth':>9}{NC}")
    for company in sorted(enforcement):
        st = enforcement[company]
        allowed = sum(v for k, v in st.items() if k.startswith("2"))
        denied = sum(v for k, v in st.items() if k in ("400", "403"))
        throttled = st.get("429", 0)
        unauth = st.get("401", 0)
        print(f"  {company:<16}{allowed:>9}{RED if denied else ''}{denied:>9}{NC if denied else ''}"
              f"{YELLOW if throttled else ''}{throttled:>11}{NC if throttled else ''}{unauth:>9}")
    print(f"\n  {DIM}Denied = a tool call the entitlement policy rejected. Throttled = over quota.{NC}")
    print(f"  {DIM}Tool-call counts above include rejected attempts; a production rate card{NC}")
    print(f"  {DIM}would bill on successful calls only.{NC}\n")


def print_report(rows, window, by_tool):
    period = f"trailing {window}" if window else "since gateway start"
    print(f"\n{BOLD}MCP Federation — Chargeback Report{NC}")
    print(f"{DIM}Source: agentgateway_mcp_requests_total · period: {period} · "
          f"rates: scripts/pricing.json{NC}\n")

    if not rows:
        print(f"  {YELLOW}No tool calls recorded yet.{NC}")
        print(f"  {DIM}Generate some traffic first — e.g. ./demo.sh, or"
              f" scripts/mcp.py call acme billing payments_get_payment '{{\"payment_id\":\"p1\"}}'{NC}\n")
        return

    companies = sorted({r["company"] for r in rows})
    grand_calls = grand_amount = 0.0

    for company in companies:
        crows = [r for r in rows if r["company"] == company]
        tier = crows[0]["tier"]
        calls = sum(r["calls"] for r in crows)
        amount = sum(r["amount"] for r in crows)
        grand_calls += calls
        grand_amount += amount

        print(f"{BOLD}{CYAN}{company}{NC} {DIM}({tier} tier){NC}")
        for domain in sorted({r["domain"] for r in crows}):
            drows = [r for r in crows if r["domain"] == domain]
            dcalls = sum(r["calls"] for r in drows)
            damount = sum(r["amount"] for r in drows)
            print(f"    {domain:<12} {dcalls:>6} calls   {GREEN}${damount:>9.4f}{NC}")
            if by_tool:
                for r in sorted(drows, key=lambda r: -r["amount"]):
                    # Pad the joined "server.tool" — padding the tool alone leaves
                    # the columns ragged, since server names differ in length.
                    label = f"{r['server']}.{r['tool']}"
                    print(f"      {DIM}{label:<34}{NC}"
                          f"{r['calls']:>5} × ${r['rate']:.4f} = ${r['amount']:>8.4f}")
        print(f"    {BOLD}{'subtotal':<12} {calls:>6} calls   ${amount:>9.4f}{NC}\n")

    print(f"{BOLD}{'TOTAL':<16} {int(grand_calls):>6} calls   ${grand_amount:>9.4f}{NC}\n")

    unattributed = [r for r in rows if r["company"] == "(unattributed)"]
    if unattributed:
        print(f"{YELLOW}note:{NC} {sum(r['calls'] for r in unattributed)} calls carry no company "
              f"label — traffic recorded before the metering policy was applied.\n")


def main():
    args = sys.argv[1:]
    window = None
    if "--window" in args:
        window = args[args.index("--window") + 1]
    rows = price_rows(collect(window))
    if "--csv" in args:
        print_csv(rows)
    else:
        print_report(rows, window, "--by-tool" in args)
        print_enforcement(collect_enforcement(window))


if __name__ == "__main__":
    main()
