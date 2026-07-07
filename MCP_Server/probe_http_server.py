#!/usr/bin/env python3
"""Probe the ReaperAI MCP HTTP server and persist a small status snapshot."""

from __future__ import annotations

import argparse
import json
import socket
import time
import urllib.request
from pathlib import Path


HOST = "127.0.0.1"
PORT = 8765


def is_port_open() -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.4)
        return sock.connect_ex((HOST, PORT)) == 0


def listening_pid() -> str | None:
    # Avoid spawning netstat from pythonw. On Windows 11 this can create
    # WindowsTerminal/OpenConsole windows on some machines.
    return None


def read_json_url(path: str, timeout: float) -> tuple[dict | None, str | None, str | None]:
    url = f"http://{HOST}:{PORT}{path}"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
        return json.loads(raw), raw, None
    except Exception as exc:
        return None, None, str(exc)


def probe_once(server_dir: Path) -> dict:
    endpoint_path = server_dir / "mcp_server_endpoints.json"
    status = {
        "checked_at": time.time(),
        "ok": False,
        "ping_ok": False,
        "port_open": is_port_open(),
        "pid": listening_pid(),
        "endpoint_count": 0,
        "state": "offline",
        "detail": "",
    }

    ping_data, _ping_raw, ping_error = read_json_url("/ping", 0.8)
    if isinstance(ping_data, dict) and ping_data.get("ok") is True:
        status["ok"] = True
        status["ping_ok"] = True
        status["port_open"] = True
        status["pid"] = listening_pid()
        status["state"] = "connected"
        status["detail"] = "ping ok"
    else:
        status["detail"] = ping_error or "ping failed"
        return status

    endpoints_data, endpoints_raw, endpoints_error = read_json_url("/list_endpoints", 1.8)
    if isinstance(endpoints_data, dict):
        count = endpoints_data.get("count")
        if not isinstance(count, int):
            endpoints = endpoints_data.get("endpoints")
            count = len(endpoints) if isinstance(endpoints, dict) else 0
        status["endpoint_count"] = int(count or 0)
        if endpoints_raw:
            endpoint_path.write_text(endpoints_raw, encoding="utf-8")
    elif endpoints_error:
        status["detail"] = f"ping ok, endpoints failed: {endpoints_error}"

    return status


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wait", type=float, default=0.0)
    args = parser.parse_args()

    server_dir = Path(__file__).resolve().parent
    status_path = server_dir / "mcp_server_status.json"
    deadline = time.time() + max(0.0, args.wait)
    last_status: dict | None = None

    while True:
        last_status = probe_once(server_dir)
        if last_status.get("ok") or time.time() >= deadline:
            break
        time.sleep(0.4)

    status_path.write_text(json.dumps(last_status, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0 if last_status and last_status.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
