#!/usr/bin/env python3
"""Extract reaper.xxx() API candidates from ReaperAI source files."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


REAPER_DOT_CALL = re.compile(r"reaper\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(")
REAPER_INDEX_CALL = re.compile(r"reaper\s*\[\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\s*\]\s*\(")


def iter_source_files(paths: list[Path]):
    for root in paths:
        if root.is_file():
            yield root
        elif root.is_dir():
            for pattern in ("*.lua", "*.py"):
                yield from root.rglob(pattern)


def extract_candidates(text: str) -> set[str]:
    names = set(REAPER_DOT_CALL.findall(text))
    names.update(REAPER_INDEX_CALL.findall(text))
    return names


def portable_source_path(path: Path, reaper_root: Path) -> str:
    """Store source paths relative to the REAPER resource root for release portability."""
    try:
        rel = path.resolve().relative_to(reaper_root.resolve())
        return "${REAPER_RESOURCE_PATH}/" + rel.as_posix()
    except ValueError:
        return path.name


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", action="append", default=[], help="File or directory to scan")
    parser.add_argument("--out", required=True, help="Output JSON path")
    args = parser.parse_args()

    server_dir = Path(__file__).resolve().parents[1]
    reaper_root = server_dir.parent
    roots = [Path(p) for p in args.root] or [
        reaper_root / "Scripts",
        server_dir,
    ]
    by_file: dict[str, list[str]] = {}
    all_names: set[str] = set()
    for path in iter_source_files(roots):
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        names = sorted(extract_candidates(text))
        if names:
            by_file[portable_source_path(path, reaper_root)] = names
            all_names.update(names)

    payload = {
        "schema": "reaperai.reaper_api_candidates.v1",
        "count": len(all_names),
        "candidates": sorted(all_names),
        "by_file": by_file,
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {len(all_names)} candidates to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
