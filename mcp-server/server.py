#!/usr/bin/env python3
"""
Generic stub MCP server — Streamable HTTP, Python standard library only.

Why stdlib-only: this demo has to be handed to a customer and just run. No image
to build, no registry to push to, no `pip install` at pod start (which would make
the demo depend on egress to PyPI). The pod runs a stock `python:3.12-alpine`
image, mounts this file plus a tool spec from a ConfigMap, and serves MCP.

One image, six servers: everything specific to a given server — its name, its
tools, their schemas, and the fake data they return — comes from a JSON tool spec
(TOOLS_FILE). See manifests/mcp-servers/ for the six specs this demo uses.

Protocol: MCP Streamable HTTP (2025-06-18).
  POST <any path>  → JSON-RPC request/notification
  GET  <any path>  → 405 (this server never initiates streams)
  DELETE <any path>→ 204 (session teardown)

Responses are sent as SSE when the caller's Accept header allows it (this is what
agentgateway sends, and what the reference MCP servers do) and as plain JSON
otherwise. Both are legal per the spec.

Env:
  TOOLS_FILE   path to the JSON tool spec   (default /etc/mcp/tools.json)
  PORT         listen port                  (default 8080)
"""

import hashlib
import json
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL_VERSION = "2025-06-18"

TOOLS_FILE = os.environ.get("TOOLS_FILE", "/etc/mcp/tools.json")
PORT = int(os.environ.get("PORT", "8080"))

with open(TOOLS_FILE) as fh:
    SPEC = json.load(fh)

SERVER_NAME = SPEC.get("server", "stub")
TOOLS = SPEC.get("tools", [])
TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


def _seeded_int(*parts, lo=1000, hi=9999):
    """Stable pseudo-random int so repeated calls return the same fake data.

    Demos get replayed. A tool that returns a different invoice number every
    time it is called makes the walkthrough look broken rather than realistic.
    """
    digest = hashlib.sha256("|".join(str(p) for p in parts).encode()).hexdigest()
    return lo + (int(digest[:8], 16) % (hi - lo + 1))


def _render(value, args, tool_name):
    """Fill {placeholders} in the canned response from the call's arguments.

    Anything not supplied by the caller is replaced with stable fake data rather
    than left as a literal brace, so a tool called with no arguments still
    returns something that reads like a real API response.
    """
    if isinstance(value, dict):
        return {k: _render(v, args, tool_name) for k, v in value.items()}
    if isinstance(value, list):
        return [_render(v, args, tool_name) for v in value]
    if isinstance(value, str):
        out = value
        for key, val in args.items():
            out = out.replace("{" + key + "}", str(val))
        # Generated fields the spec can ask for.
        if "{id}" in out:
            out = out.replace("{id}", str(_seeded_int(tool_name, json.dumps(args, sort_keys=True))))
        if "{today}" in out:
            out = out.replace("{today}", datetime.now(timezone.utc).strftime("%Y-%m-%d"))
        if "{next_month}" in out:
            nxt = datetime.now(timezone.utc) + timedelta(days=30)
            out = out.replace("{next_month}", nxt.strftime("%Y-%m-%d"))
        # Any placeholder the caller did not supply becomes a plausible value
        # instead of leaking "{arg}" into the response.
        while "{" in out and "}" in out:
            start = out.index("{")
            end = out.index("}", start)
            if end < start:
                break
            name = out[start + 1:end]
            out = out[:start] + f"{name}-{_seeded_int(tool_name, name)}" + out[end + 1:]
        return out
    return value


def call_tool(name, args):
    tool = TOOLS_BY_NAME.get(name)
    if tool is None:
        return None
    return _render(tool.get("response", {"ok": True}), args or {}, name)


def handle_rpc(msg):
    """Return a JSON-RPC response dict, or None for notifications."""
    method = msg.get("method")
    msg_id = msg.get("id")

    def ok(result):
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}

    def err(code, message):
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}

    if method == "initialize":
        return ok({
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {
                "name": SERVER_NAME,
                "title": SPEC.get("displayName", SERVER_NAME),
                "version": SPEC.get("version", "1.0.0"),
            },
            "instructions": SPEC.get("instructions", ""),
        })

    if method == "ping":
        return ok({})

    if method == "tools/list":
        return ok({
            "tools": [
                {
                    "name": t["name"],
                    "description": t.get("description", ""),
                    "inputSchema": t.get("inputSchema", {"type": "object", "properties": {}}),
                }
                for t in TOOLS
            ]
        })

    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        result = call_tool(name, args)
        if result is None:
            return err(-32602, f"unknown tool: {name}")
        return ok({
            "content": [{"type": "text", "text": json.dumps(result, indent=2)}],
            "isError": False,
        })

    # resources/prompts are not part of this demo; answer empty rather than error
    # so clients that probe for them during initialization stay happy.
    if method == "resources/list":
        return ok({"resources": []})
    if method == "prompts/list":
        return ok({"prompts": []})

    if method is not None and method.startswith("notifications/"):
        return None

    return err(-32601, f"method not found: {method}")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"stub-mcp/{SERVER_NAME}"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _wants_sse(self):
        return "text/event-stream" in (self.headers.get("Accept") or "")

    def _send(self, status, body=b"", content_type=None, extra_headers=None):
        self.send_response(status)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, val in (extra_headers or {}).items():
            self.send_header(key, val)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        # Health probe for Kubernetes; every other GET is an SSE stream request,
        # which this server does not support (it never pushes unsolicited messages).
        if self.path.rstrip("/").endswith("/healthz"):
            self._send(200, b'{"status":"ok"}', "application/json")
            return
        self._send(405, b"", "text/plain")

    def do_DELETE(self):
        self._send(204)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send(400, b'{"error":"invalid json"}', "application/json")
            return

        batch = payload if isinstance(payload, list) else [payload]
        responses = [r for r in (handle_rpc(m) for m in batch) if r is not None]

        headers = {}
        # A fresh session id on initialize; clients echo it back on later calls.
        if any(m.get("method") == "initialize" for m in batch):
            headers["Mcp-Session-Id"] = uuid.uuid4().hex

        if not responses:
            # Notifications only — nothing to return.
            self._send(202, b"", None, headers)
            return

        out = responses if isinstance(payload, list) else responses[0]
        body = json.dumps(out).encode()

        if self._wants_sse():
            sse = b"event: message\ndata: " + body + b"\n\n"
            self._send(200, sse, "text/event-stream", headers)
        else:
            self._send(200, body, "application/json", headers)


if __name__ == "__main__":
    print(
        f"stub MCP server '{SERVER_NAME}' listening on :{PORT} "
        f"with {len(TOOLS)} tools: {', '.join(sorted(TOOLS_BY_NAME))}",
        flush=True,
    )
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
