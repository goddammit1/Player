# -*- coding: utf-8 -*-
# Re-saves all *.dart files in lib/ and test/ as UTF-8 (no BOM, LF endings).
#
# Why: on Windows some files ended up in cp1251 / UTF-16 with BOM, so the
# Dart analyzer reports "Target of URI doesn't exist" on import.
#
# Usage:
#     python tools/fix_encoding.py

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET_DIRS = [ROOT / "lib", ROOT / "test"]

CANDIDATE_ENCODINGS = [
    "utf-8-sig",
    "utf-16",
    "utf-16-le",
    "utf-16-be",
    "utf-8",
    "cp1251",
    "cp1252",
]


def decode(raw: bytes) -> tuple[str, str]:
    for enc in CANDIDATE_ENCODINGS:
        try:
            return raw.decode(enc), enc
        except UnicodeDecodeError:
            continue
    raise RuntimeError("cannot decode")


def process(path: Path) -> tuple[bool, str]:
    original = path.read_bytes()
    text, enc = decode(original)
    new_bytes = text.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")
    if new_bytes == original:
        return False, enc
    path.write_bytes(new_bytes)
    return True, enc


def main() -> int:
    changed = 0
    seen = 0
    for base in TARGET_DIRS:
        if not base.exists():
            continue
        for f in base.rglob("*.dart"):
            seen += 1
            try:
                touched, enc = process(f)
                if touched:
                    rel = f.relative_to(ROOT).as_posix()
                    print(f"  fixed ({enc} -> utf-8): {rel}")
                    changed += 1
            except Exception as e:
                print(f"  ERROR {f}: {e}", file=sys.stderr)
    print(f"\nDone. Seen: {seen}, re-encoded: {changed}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
