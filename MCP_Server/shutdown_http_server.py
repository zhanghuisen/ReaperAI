#!/usr/bin/env python3
"""Ask the ReaperAI MCP server to shut down without opening a console window."""

from __future__ import annotations

import json
import socket
import time
import urllib.request
from pathlib import Path


HOST = "127.0.0.1"
PORT = 8765


def is_port_open() -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex((HOST, PORT)) == 0


def listening_pid() -> str | None:
    # Avoid spawning netstat from pythonw. On Windows 11 this can create
    # WindowsTerminal/OpenConsole windows on some machines.
    return None


def main() -> int:
    server_dir = Path(__file__).resolve().parent
    log_path = server_dir / "mcp_server_shutdown.log"
    status_path = server_dir / "mcp_server_status.json"
    status = {"requested_at": time.time(), "ok": False, "method": "none"}

    try:
        req = urllib.request.Request(f"http://{HOST}:{PORT}/shutdown", data=b"{}", method="POST")
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            status["shutdown_response"] = resp.read(200).decode("utf-8", errors="replace")
            status["method"] = "shutdown"
    except Exception as exc:
        status["shutdown_error"] = str(exc)

    deadline = time.time() + 4
    while time.time() < deadline:
        if not is_port_open():
            status["ok"] = True
            status["method"] = status.get("method") or "shutdown"
            break
        time.sleep(0.25)

    if not status["ok"]:
        status["pid"] = None
        status["method"] = "shutdown_timeout"
        status["detail"] = "HTTP shutdown did not close the port within timeout; taskkill fallback disabled to avoid Windows Terminal windows"

    log_path.write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
    status_path.write_text(
        json.dumps(
            {
                "checked_at": time.time(),
                "ok": False,
                "ping_ok": False,
                "port_open": is_port_open(),
                "pid": listening_pid(),
                "endpoint_count": 0,
                "state": "offline" if status["ok"] else "unknown",
                "detail": "shutdown confirmed" if status["ok"] else "shutdown not confirmed",
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    return 0 if status["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
