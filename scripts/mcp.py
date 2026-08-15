#!/usr/bin/env python3
"""
MCP client for the federation demo — authenticates as a company, then talks MCP.

This is what a customer's agent does, minus the LLM: get a token from your own
OAuth provider, open an MCP session against the shared federated endpoint, and
use whatever tools come back. The tool list you receive is already filtered to
your entitlements; there is no client-side allow-list anywhere in this file.

Usage:
  mcp.py list    <company> <domain>              tools this company can see
  mcp.py call    <company> <domain> <tool> [json]  invoke a tool
  mcp.py matrix                                  entitlement matrix, all companies
  mcp.py quota   <company> [count]               fire N requests, show quota kicking in
  mcp.py token   <company>                       print a raw access token + claims

  company = acme | globex | initech
  domain  = billing | analytics | support

Env:
  GATEWAY_URL   default http://localhost:8080
  KEYCLOAK_URL  default http://localhost:8081

Standard library only — no pip install to run the demo.
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://localhost:8080").rstrip("/")
KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://localhost:8081").rstrip("/")

# Companies are not hardcoded so an onboarded partner works with these tools
# immediately: `COMPANIES=acme,globex,initech,umbrella scripts/mcp.py matrix`.
COMPANIES = [c for c in os.environ.get("COMPANIES", "acme,globex,initech").split(",") if c]
DOMAINS = ["billing", "analytics", "support"]

BOLD = "\033[1m"
DIM = "\033[2m"
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
NC = "\033[0m"


def die(msg):
    print(f"{RED}error:{NC} {msg}", file=sys.stderr)
    sys.exit(1)


class QuotaExceeded(Exception):
    """Raised on HTTP 429 so callers can decide whether it is fatal.

    For a single list/call it is a hard stop, but the entitlement matrix opens a
    session per company per domain and should report a throttled cell rather than
    abandoning the whole table.
    """


def get_token(company):
    """client_credentials against that company's OWN realm."""
    url = f"{KEYCLOAK_URL}/realms/{company}/protocol/openid-connect/token"
    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": f"{company}-agent",
        "client_secret": f"{company}-secret",
    }).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=15) as resp:
            return json.load(resp)["access_token"]
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            die(f"no realm '{company}' in Keycloak — known realms: {', '.join(COMPANIES)}.\n"
                f"       Onboard a new one with scripts/add-partner.sh, then set\n"
                f"       COMPANIES={','.join(COMPANIES)},{company} to include it here.")
        die(f"Keycloak rejected the token request for '{company}' (HTTP {exc.code}).")
    except urllib.error.URLError as exc:
        die(f"could not reach Keycloak at {KEYCLOAK_URL} ({exc}).\n"
            f"       Is ./port-forward.sh running?")


def decode_claims(token):
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def company_of(token):
    return decode_claims(token).get("company", "unknown")


def _parse_body(raw):
    """Responses come back as SSE or plain JSON depending on negotiation."""
    text = raw.decode()
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            line = line[5:].strip()
        if not line:
            continue
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    return None


class Session:
    """One MCP session against a federated endpoint."""

    def __init__(self, domain, token):
        self.url = f"{GATEWAY_URL}/mcp/{domain}"
        self.token = token
        self.sid = None

    def _post(self, payload):
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Authorization": f"Bearer {self.token}",
        }
        if self.sid:
            headers["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(self.url, data=json.dumps(payload).encode(), headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                if not self.sid:
                    self.sid = resp.headers.get("Mcp-Session-Id")
                return resp.status, _parse_body(resp.read())
        except urllib.error.HTTPError as exc:
            return exc.code, _parse_body(exc.read())
        except urllib.error.URLError as exc:
            die(f"could not reach the gateway at {GATEWAY_URL} ({exc}).\n"
                f"       Is ./port-forward.sh running?")

    def open(self):
        status, body = self._post({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "federation-demo", "version": "1.0"},
            },
        })
        if status == 401:
            die("gateway rejected the token (401). The JWT authentication policy is doing its job.")
        if status == 429:
            raise QuotaExceeded(f"{company_of(self.token)} has exhausted its quota for this minute")
        if status != 200:
            die(f"initialize failed with HTTP {status}: {body}")
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return self

    def list_tools(self):
        _, body = self._post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        if not body or "result" not in body:
            return []
        return body["result"].get("tools", [])

    def call_tool(self, name, args):
        _, body = self._post({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": name, "arguments": args},
        })
        return body


def cmd_token(company):
    token = get_token(company)
    claims = decode_claims(token)
    print(f"{BOLD}{company}{NC} — issued by {claims['iss']}")
    print(f"  company : {GREEN}{claims.get('company')}{NC}")
    print(f"  tier    : {GREEN}{claims.get('tier')}{NC}")
    print(f"  aud     : {claims.get('aud')}")
    print()
    print(token)


def cmd_list(company, domain):
    try:
        tools = Session(domain, get_token(company)).open().list_tools()
    except QuotaExceeded as exc:
        print(f"\n{YELLOW}quota exceeded (HTTP 429){NC} — {exc}\n")
        sys.exit(2)
    print(f"\n{BOLD}{company}{NC} → {BOLD}/mcp/{domain}{NC}  "
          f"{DIM}({len(tools)} tools visible){NC}\n")
    if not tools:
        print(f"  {DIM}(no tools — this company has no entitlement in this domain){NC}\n")
        return
    server = None
    for tool in tools:
        # Federated names are <server>_<tool>; group them for readability.
        prefix = tool["name"].split("_", 1)[0]
        if prefix != server:
            server = prefix
            print(f"  {CYAN}{server}{NC}")
        desc = (tool.get("description") or "").split(".")[0]
        print(f"    {GREEN}✓{NC} {tool['name']:<38} {DIM}{desc[:60]}{NC}")
    print()


def cmd_call(company, domain, tool, args_json):
    args = json.loads(args_json) if args_json else {}
    try:
        body = Session(domain, get_token(company)).open().call_tool(tool, args)
    except QuotaExceeded as exc:
        print(f"\n{YELLOW}quota exceeded (HTTP 429){NC} — {exc}\n")
        sys.exit(2)
    print(f"\n{BOLD}{company}{NC} → {BOLD}/mcp/{domain}{NC} → {BOLD}{tool}{NC}\n")
    if body and "error" in body:
        print(f"  {RED}✗ denied{NC}: {body['error'].get('message')}")
        print(f"  {DIM}Tools this company is not entitled to are not merely blocked —{NC}")
        print(f"  {DIM}they are invisible, so the caller cannot tell they exist.{NC}\n")
        return 1
    if body and "result" in body:
        for item in body["result"].get("content", []):
            for line in (item.get("text") or "").splitlines():
                print(f"  {line}")
        print()
        return 0
    print(f"  {RED}unexpected response{NC}: {body}\n")
    return 1


def cmd_matrix():
    """The whole point of the demo on one screen."""
    print(f"\n{BOLD}Entitlement matrix — one federated endpoint per domain, "
          f"three different views{NC}\n")
    results = {}
    throttled = set()
    for company in COMPANIES:
        token = get_token(company)
        for domain in DOMAINS:
            try:
                tools = Session(domain, token).open().list_tools()
                results[(company, domain)] = [t["name"] for t in tools]
            except QuotaExceeded:
                # Reading the matrix costs quota too. Show the gap rather than
                # dying halfway through the table.
                results[(company, domain)] = []
                throttled.add((company, domain))

    # Columns are padded by hand: ANSI colour codes have zero display width, so
    # f-string alignment on a coloured string pads to the wrong place.
    name_w, col_w = 36, 11

    def centred(text, colour=""):
        pad = col_w - len(text)
        left = pad // 2
        return " " * left + colour + text + (NC if colour else "") + " " * (pad - left)

    print(f"{BOLD}{'':<{name_w}}" + "".join(centred(c) for c in COMPANIES) + f"{NC}")
    for domain in DOMAINS:
        counts = "".join(centred(str(len(results[(c, domain)]))) for c in COMPANIES)
        print(f"{BOLD}/mcp/{domain:<{name_w - 5}}{NC}{counts}{DIM}  tools visible{NC}")

        # Union of every tool any company sees in this domain, so the gaps show.
        every = sorted({n for c in COMPANIES for n in results[(c, domain)]})
        for name in every:
            cells = ""
            for company in COMPANIES:
                granted = name in results[(company, domain)]
                cells += centred("✓" if granted else "·", GREEN if granted else RED)
            print(f"  {DIM}{name:<{name_w - 2}}{NC}{cells}")
        print()
    print(f"{DIM}✓ = visible and callable   · = filtered out by the gateway{NC}")
    if throttled:
        cells = ", ".join(f"{c}/{d}" for c, d in sorted(throttled))
        print(f"{YELLOW}note:{NC} quota exhausted while reading {cells} — "
              f"wait a minute and re-run for a complete table")
    print()


def cmd_quota(company, count):
    token = get_token(company)
    claims = decode_claims(token)
    print(f"\n{BOLD}{company}{NC} ({claims.get('tier')} tier) — sending {count} requests\n")
    allowed = throttled = 0
    for i in range(1, count + 1):
        url = f"{GATEWAY_URL}/mcp/analytics"
        req = urllib.request.Request(
            url,
            data=json.dumps({
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                           "clientInfo": {"name": "quota-probe", "version": "1"}},
            }).encode(),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Authorization": f"Bearer {token}",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                status = resp.status
                resp.read()
        except urllib.error.HTTPError as exc:
            status = exc.code
            exc.read()
        if status == 429:
            throttled += 1
            print(f"  request {i:>3} → {RED}HTTP 429 quota exceeded{NC}")
        else:
            allowed += 1
            print(f"  request {i:>3} → {GREEN}HTTP {status}{NC}")
    print(f"\n  {allowed} allowed, {throttled} throttled — the counter is shared across every "
          f"gateway replica\n")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    args = sys.argv[2:]
    if cmd == "matrix":
        cmd_matrix()
    elif cmd == "token" and len(args) == 1:
        cmd_token(args[0])
    elif cmd == "list" and len(args) == 2:
        cmd_list(args[0], args[1])
    elif cmd == "call" and len(args) >= 3:
        sys.exit(cmd_call(args[0], args[1], args[2], args[3] if len(args) > 3 else None))
    elif cmd == "quota" and len(args) >= 1:
        cmd_quota(args[0], int(args[1]) if len(args) > 1 else 8)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
