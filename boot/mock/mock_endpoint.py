#!/usr/bin/env python3
"""Stdlib-only OpenAI-compatible inference endpoint for the minimal-boot harness.

Why this exists
---------------
The minimal-boot measurements in ``boot/README.md`` were taken without ever
executing a turn in which the model actually *called a tool*, and every probe
ran against a plaintext loopback socket.  Both gaps are closed here: this
server speaks the streaming tool-call wire format (with deliberately
fragmented ``arguments`` deltas, which is where SSE reassembly bugs live) and
can serve over TLS with a self-signed CA so the ``agent/ssl_guard.py`` path and
real certificate validation are exercised.

No third-party imports.  It must run on the minimal rootfs itself, whose only
wheels are the tier-4 set.

Scenarios (``--scenario`` / ``MOCK_SCENARIO``)
    plain     one assistant message, ``finish_reason=stop``
    toolcall  first request returns tool_calls, second returns prose
    retry     first ``--fail-times`` requests return 429 + Retry-After
    reset     first request dies mid-stream (socket closed), then succeeds

Every request is appended to ``--log`` as JSONL, including the tool names the
agent advertised.  ``boot/scripts/verify.sh`` asserts against that file, so the
"how many tools does one turn actually offer the model" question is measured
rather than assumed.
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_LOCK = threading.Lock()
STATE = {"requests": 0, "connections": 0, "chat_requests": 0}
CONFIG: dict = {}


def _log_event(event: dict) -> None:
    path = CONFIG.get("log")
    if not path:
        return
    event["ts"] = round(time.time(), 6)
    line = json.dumps(event, sort_keys=True)
    with STATE_LOCK:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def _chunk(model: str, cid: str, delta: dict, finish: str | None = None) -> str:
    payload = {
        "id": cid,
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish, "logprobs": None}],
    }
    return "data: " + json.dumps(payload) + "\n\n"


def _fragment(text: str, size: int = 3) -> list[str]:
    """Split a string into small pieces so reassembly is genuinely tested."""
    return [text[i : i + size] for i in range(0, len(text), size)] or [""]


def _synthesize_structured(response_format: dict) -> str:
    """Return a JSON body satisfying a ``response_format`` json_schema request.

    Hermes' session-title call uses strict json_schema mode; returning prose
    there aborts the turn, so honour the schema shape rather than guessing.
    """
    schema = ((response_format or {}).get("json_schema") or {}).get("schema") or {}
    props = schema.get("properties") or {}
    out: dict = {}
    for key, spec in props.items():
        kind = (spec or {}).get("type")
        if kind == "string":
            out[key] = "minimal-boot"
        elif kind in ("integer", "number"):
            out[key] = 1
        elif kind == "boolean":
            out[key] = True
        elif kind == "array":
            out[key] = []
        elif kind == "object":
            out[key] = {}
        else:
            out[key] = "minimal-boot"
    if not out:
        out = {"title": "minimal-boot"}
    return json.dumps(out)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockInference/1.0"

    # Silence the default stderr access log; we keep our own JSONL.
    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        if CONFIG.get("verbose"):
            sys.stderr.write("[mock] " + (fmt % args) + "\n")

    # ---------- helpers ----------

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw or b"{}")
        except Exception:
            return {}

    def _send_json(self, code: int, body: dict, extra: dict | None = None) -> None:
        blob = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(blob)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(blob)

    def _begin_sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

    def _write_sse(self, text: str) -> None:
        self.wfile.write(text.encode())
        self.wfile.flush()

    # ---------- routes ----------

    def do_GET(self) -> None:  # noqa: N802
        with STATE_LOCK:
            STATE["requests"] += 1
        _log_event({"kind": "http", "method": "GET", "path": self.path,
                    "host": self.headers.get("Host", "")})
        if self.path.rstrip("/").endswith("/models"):
            self._send_json(200, {"object": "list", "data": [
                {"id": CONFIG["model"], "object": "model", "owned_by": "mock"}]})
        elif self.path.rstrip("/") in ("/__stats", "/__stats/"):
            with STATE_LOCK:
                self._send_json(200, dict(STATE))
        else:
            self._send_json(404, {"error": {"message": "not found", "type": "invalid_request_error"}})

    def do_POST(self) -> None:  # noqa: N802
        body = self._read_json()
        with STATE_LOCK:
            STATE["requests"] += 1
            is_chat = "chat/completions" in self.path
            if is_chat:
                STATE["chat_requests"] += 1
                turn = STATE["chat_requests"]
            else:
                turn = 0

        messages = body.get("messages") or []
        tools = body.get("tools") or []
        tool_names = sorted(
            (t.get("function") or {}).get("name", "?") for t in tools if isinstance(t, dict)
        )
        response_format = body.get("response_format")

        _log_event({
            "kind": "chat" if is_chat else "http",
            "method": "POST",
            "path": self.path,
            "host": self.headers.get("Host", ""),
            "turn": turn,
            "stream": bool(body.get("stream")),
            "model": body.get("model"),
            "message_count": len(messages),
            "message_roles": [m.get("role") for m in messages if isinstance(m, dict)],
            "tool_count": len(tools),
            "tool_names": tool_names,
            "structured": bool(response_format),
            "temperature": body.get("temperature"),
            "has_tool_result": any(
                isinstance(m, dict) and m.get("role") == "tool" for m in messages
            ),
        })

        if not is_chat:
            self._send_json(404, {"error": {"message": "not found", "type": "invalid_request_error"}})
            return

        # A structured-output request is always answered on its own terms; it is
        # the session-title call, not the agent turn, and scenarios must not
        # swallow it.
        if response_format:
            self._respond_text(body, _synthesize_structured(response_format))
            return

        scenario = CONFIG["scenario"]

        if scenario == "retry" and turn <= CONFIG["fail_times"]:
            self._send_json(
                429,
                {"error": {"message": "mock rate limit", "type": "rate_limit_error"}},
                extra={"Retry-After": "1"},
            )
            return

        if scenario == "reset" and turn == 1:
            # Emit a partial stream then hang up, so the reconnect path runs.
            if body.get("stream"):
                cid = "chatcmpl-" + uuid.uuid4().hex[:16]
                self._begin_sse()
                self._write_sse(_chunk(CONFIG["model"], cid, {"role": "assistant"}))
                self._write_sse(_chunk(CONFIG["model"], cid, {"content": "part"}))
            try:
                self.wfile.flush()
            except Exception:
                pass
            self.close_connection = True
            try:
                self.connection.close()
            except Exception:
                pass
            return

        wants_tool = (
            scenario == "toolcall"
            and tools
            and not any(isinstance(m, dict) and m.get("role") == "tool" for m in messages)
        )

        if wants_tool:
            self._respond_toolcall(body, tools)
        else:
            self._respond_text(body, CONFIG["reply"])

    # ---------- response builders ----------

    def _respond_text(self, body: dict, content: str) -> None:
        model = body.get("model") or CONFIG["model"]
        cid = "chatcmpl-" + uuid.uuid4().hex[:16]
        if body.get("stream"):
            self._begin_sse()
            self._write_sse(_chunk(model, cid, {"role": "assistant", "content": ""}))
            for piece in _fragment(content, 4):
                self._write_sse(_chunk(model, cid, {"content": piece}))
            self._write_sse(_chunk(model, cid, {}, finish="stop"))
            self._write_sse("data: [DONE]\n\n")
            return
        self._send_json(200, {
            "id": cid,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
                "logprobs": None,
            }],
            "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18},
        })

    def _pick_tool(self, tools: list) -> tuple[str, str]:
        """Choose a tool to call and build plausible arguments for it.

        Preference order favours a shell-ish tool, because the shell-out tier is
        the part of the byte ledger that no prior probe ever exercised.
        """
        names = [(t.get("function") or {}).get("name", "") for t in tools if isinstance(t, dict)]
        wanted = CONFIG.get("tool_name") or ""
        if wanted and wanted in names:
            chosen = wanted
        else:
            chosen = next(
                (n for n in ("bash", "terminal", "execute_command", "run_command", "shell")
                 if n in names),
                names[0] if names else "bash",
            )
        spec = next(
            (t for t in tools if (t.get("function") or {}).get("name") == chosen),
            None,
        )
        props = (((spec or {}).get("function") or {}).get("parameters") or {}).get("properties") or {}
        required = (((spec or {}).get("function") or {}).get("parameters") or {}).get("required") or []
        args: dict = {}
        cmd = CONFIG.get("tool_command") or "echo minimal-boot-tool-ran"
        for key in (required or list(props)[:1]):
            spec_k = props.get(key) or {}
            kind = spec_k.get("type")
            if kind == "string":
                args[key] = cmd if key in ("command", "cmd", "script", "code", "input") else cmd
            elif kind in ("integer", "number"):
                args[key] = 1
            elif kind == "boolean":
                args[key] = False
            elif kind == "array":
                args[key] = [cmd]
            else:
                args[key] = cmd
        if not args:
            args = {"command": cmd}
        return chosen, json.dumps(args)

    def _respond_toolcall(self, body: dict, tools: list) -> None:
        model = body.get("model") or CONFIG["model"]
        cid = "chatcmpl-" + uuid.uuid4().hex[:16]
        name, arguments = self._pick_tool(tools)
        call_id = "call_" + uuid.uuid4().hex[:20]
        _log_event({"kind": "toolcall_issued", "tool": name, "arguments": arguments})

        if body.get("stream"):
            self._begin_sse()
            self._write_sse(_chunk(model, cid, {"role": "assistant", "content": None}))
            # Name and id arrive in their own delta, arguments in fragments —
            # this is the shape real providers emit and the shape that breaks
            # naive accumulators.
            self._write_sse(_chunk(model, cid, {"tool_calls": [{
                "index": 0, "id": call_id, "type": "function",
                "function": {"name": name, "arguments": ""},
            }]}))
            for piece in _fragment(arguments, 2):
                self._write_sse(_chunk(model, cid, {"tool_calls": [{
                    "index": 0,
                    "function": {"arguments": piece},
                }]}))
            self._write_sse(_chunk(model, cid, {}, finish="tool_calls"))
            self._write_sse("data: [DONE]\n\n")
            return

        self._send_json(200, {
            "id": cid,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [{
                        "id": call_id,
                        "type": "function",
                        "function": {"name": name, "arguments": arguments},
                    }],
                },
                "finish_reason": "tool_calls",
                "logprobs": None,
            }],
            "usage": {"prompt_tokens": 21, "completion_tokens": 9, "total_tokens": 30},
        })


class CountingServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def get_request(self):
        conn, addr = super().get_request()
        with STATE_LOCK:
            STATE["connections"] += 1
        return conn, addr


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default=os.getenv("MOCK_HOST", "0.0.0.0"))
    ap.add_argument("--port", type=int, default=int(os.getenv("MOCK_PORT", "8099")))
    ap.add_argument("--scenario", default=os.getenv("MOCK_SCENARIO", "plain"),
                    choices=["plain", "toolcall", "retry", "reset"])
    ap.add_argument("--model", default=os.getenv("MOCK_MODEL", "mock-model"))
    ap.add_argument("--reply", default=os.getenv("MOCK_REPLY", "MINIMAL_BOOT_OK"))
    ap.add_argument("--fail-times", type=int, default=int(os.getenv("MOCK_FAIL_TIMES", "1")))
    ap.add_argument("--tool-name", default=os.getenv("MOCK_TOOL_NAME", ""))
    ap.add_argument("--tool-command", default=os.getenv("MOCK_TOOL_COMMAND",
                                                       "echo minimal-boot-tool-ran"))
    ap.add_argument("--log", default=os.getenv("MOCK_LOG", ""))
    ap.add_argument("--certfile", default=os.getenv("MOCK_CERTFILE", ""))
    ap.add_argument("--keyfile", default=os.getenv("MOCK_KEYFILE", ""))
    ap.add_argument("--verbose", action="store_true", default=bool(os.getenv("MOCK_VERBOSE")))
    args = ap.parse_args()

    CONFIG.update(vars(args))

    httpd = CountingServer((args.host, args.port), Handler)
    scheme = "http"
    if args.certfile:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(certfile=args.certfile, keyfile=args.keyfile or args.certfile)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"

    sys.stderr.write(
        f"[mock] {scheme}://{args.host}:{args.port}/v1 scenario={args.scenario} "
        f"model={args.model} log={args.log or '-'}\n"
    )
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
