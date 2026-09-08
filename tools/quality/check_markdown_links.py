#!/usr/bin/env python3
"""Validate repository-local links in tracked Markdown documents."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote


PROJECT_ROOT = Path(__file__).resolve().parents[2]
INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
REFERENCE_LINK = re.compile(r"^\s*\[[^\]]+\]:\s*(\S+)", re.MULTILINE)
IGNORED_PREFIXES = ("#", "http://", "https://", "mailto:", "data:")


def tracked_markdown_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z", "*.md"],
        cwd=PROJECT_ROOT,
        check=True,
        capture_output=True,
    )
    return [PROJECT_ROOT / item.decode() for item in result.stdout.split(b"\0") if item]


def normalize_target(raw_target: str) -> str:
    target = raw_target.strip()
    if target.startswith("<") and ">" in target:
        target = target[1 : target.index(">")]
    else:
        target = target.split(maxsplit=1)[0]
    return unquote(target.split("#", 1)[0].split("?", 1)[0])


def main() -> int:
    broken: list[str] = []
    for document in tracked_markdown_files():
        text = document.read_text(encoding="utf-8")
        targets = [*INLINE_LINK.findall(text), *REFERENCE_LINK.findall(text)]
        for raw_target in targets:
            if raw_target.lower().startswith(IGNORED_PREFIXES):
                continue
            target = normalize_target(raw_target)
            if not target or target.startswith("$") or "<" in target:
                continue
            resolved = (PROJECT_ROOT / target.lstrip("/")) if target.startswith("/") else (document.parent / target)
            if not resolved.exists():
                broken.append(f"{document.relative_to(PROJECT_ROOT)} -> {raw_target}")

    if broken:
        print("Broken repository-local Markdown links:", file=sys.stderr)
        for link in broken:
            print(f"  {link}", file=sys.stderr)
        return 1

    print("All repository-local Markdown links resolve")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
