#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def request_json(method: str, url: str, data: str | None, timeout: float) -> tuple[int, str]:
    payload = None if data is None else data.encode("utf-8")
    req = urllib.request.Request(url, data=payload, method=method.upper())
    req.add_header("Accept", "application/json")
    if payload is not None:
      req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", errors="replace")
        return int(getattr(resp, "status", 200)), body


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--method", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--payload", default="")
    parser.add_argument("--payload-file", default="")
    parser.add_argument("--timeout", default="5")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    out_path = Path(args.out)
    timeout = max(0.5, float(args.timeout))
    payload = args.payload if args.payload != "" else None
    if args.payload_file:
        payload = Path(args.payload_file).read_text(encoding="utf-8")

    result: dict[str, object] = {"ok": False, "status": 0, "body": "", "error": ""}
    try:
        status, body = request_json(args.method, args.url, payload, timeout)
        result["ok"] = True
        result["status"] = status
        result["body"] = body
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        result["status"] = exc.code
        result["body"] = body
        result["error"] = str(exc)
    except Exception as exc:
        result["error"] = str(exc)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_name(out_path.name + f".{os.getpid()}.tmp")
    tmp_path.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp_path, out_path)
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
