#!/usr/bin/env python3
"""Compile every embedded Python heredoc in a generated installer."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_embedded_python.py <installer>", file=sys.stderr)
        return 2

    lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    found = 0
    index = 0

    while index < len(lines):
        match = re.search(r"<<'?(PY[A-Za-z0-9_]*)'?", lines[index])
        if not match:
            index += 1
            continue

        tag = match.group(1)
        body: list[str] = []
        index += 1
        while index < len(lines) and lines[index] != tag:
            body.append(lines[index])
            index += 1
        if index == len(lines):
            raise SystemExit(f"unterminated embedded Python heredoc: {tag}")

        found += 1
        source = "\n".join(body) + "\n"
        compile(source, f"embedded-{found}-{tag}.py", "exec")
        index += 1

    if found == 0:
        raise SystemExit("no embedded Python blocks found")
    print(f"Compiled {found} embedded Python blocks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
