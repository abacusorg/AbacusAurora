#!/usr/bin/env python3
"""Merge finished Cosmologies/README.txt rows into Cosmologies/README.md.

Matches on abacus_cosmNNN root. Replaces existing table rows or appends new ones.
Leaves prose above the markdown table untouched.

Usage:
  python merge_readme_txt_to_md.py           # apply
  python merge_readme_txt_to_md.py --check   # dry-run
  python merge_readme_txt_to_md.py --csv cosmologies.csv  # also sync csv if present
"""
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

COSMO = Path(__file__).resolve().parent.parent / "Cosmologies"
TXT = COSMO / "README.txt"
MD = COSMO / "README.md"

ROOT_RE = re.compile(r"\|\s*(abacus_cosm\d+)\s*\|")


def parse_table_rows(text: str) -> dict[str, str]:
    """Map root -> full | table line (stripped newline)."""
    rows = {}
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        if line.startswith("| root") or line.startswith("| ---") or "-----" in line[:20]:
            continue
        m = ROOT_RE.match(line)
        if not m:
            continue
        rows[m.group(1)] = line.rstrip("\n")
    return rows


def merge_md(md_text: str, updates: dict[str, str]) -> tuple[str, list[str], list[str]]:
    lines = md_text.splitlines(keepends=True)
    replaced = []
    seen = set()
    out = []
    last_table_idx = -1
    for i, line in enumerate(lines):
        m = ROOT_RE.match(line) if line.startswith("|") else None
        if m and m.group(1) in updates:
            root = m.group(1)
            new = updates[root]
            if not new.endswith("\n"):
                new = new + "\n"
            # preserve whether original used \n only
            out.append(new if line.endswith("\n") else new.rstrip("\n"))
            replaced.append(root)
            seen.add(root)
            last_table_idx = len(out) - 1
        else:
            out.append(line)
            if line.startswith("|") and ROOT_RE.match(line):
                last_table_idx = len(out) - 1

    appended = []
    for root, row in updates.items():
        if root in seen:
            continue
        if not row.endswith("\n"):
            row = row + "\n"
        # insert after last table data row
        insert_at = last_table_idx + 1 if last_table_idx >= 0 else len(out)
        out.insert(insert_at, row)
        last_table_idx = insert_at
        appended.append(root)
    return "".join(out), replaced, appended


def sync_csv(csv_path: Path, updates: dict[str, str], check: bool) -> None:
    if not csv_path.is_file():
        print(f"no csv at {csv_path}; skip")
        return
    # Minimal: rewrite rows whose first column / root field matches
    rows_in = list(csv.reader(csv_path.open()))
    if not rows_in:
        return
    header = rows_in[0]
    # find root-like column
    root_idx = 0
    for i, h in enumerate(header):
        if "root" in h.lower() or h.strip() == "root":
            root_idx = i
            break
    by_root = {}
    for line in updates.values():
        parts = [p.strip() for p in line.strip().strip("|").split("|")]
        if parts:
            by_root[parts[0]] = parts

    out_rows = [header]
    seen = set()
    for row in rows_in[1:]:
        if not row:
            out_rows.append(row)
            continue
        root = row[root_idx] if root_idx < len(row) else ""
        if root in by_root:
            parts = by_root[root]
            # pad/truncate to header width
            new = (parts + [""] * len(header))[: len(header)]
            out_rows.append(new)
            seen.add(root)
        else:
            out_rows.append(row)
    for root, parts in by_root.items():
        if root not in seen:
            out_rows.append((parts + [""] * len(header))[: len(header)])
    if check:
        print(f"would sync {len(by_root)} roots into {csv_path}")
        return
    with csv_path.open("w", newline="") as f:
        csv.writer(f).writerows(out_rows)
    print(f"updated {csv_path}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="dry-run")
    ap.add_argument("--txt", type=Path, default=TXT)
    ap.add_argument("--md", type=Path, default=MD)
    ap.add_argument("--csv", type=Path, default=None, help="optional cosmologies.csv")
    args = ap.parse_args()

    if not args.txt.is_file():
        raise SystemExit(f"missing {args.txt}")
    if not args.md.is_file():
        raise SystemExit(f"missing {args.md}")

    updates = parse_table_rows(args.txt.read_text())
    if not updates:
        raise SystemExit(f"no cosm rows found in {args.txt}")

    new_md, replaced, appended = merge_md(args.md.read_text(), updates)
    print(f"from {args.txt}: {len(updates)} rows")
    print(f"replace: {replaced}")
    print(f"append:  {appended}")

    if args.check:
        print("dry-run only; not writing")
    else:
        args.md.write_text(new_md)
        print(f"wrote {args.md}")

    if args.csv:
        sync_csv(args.csv, updates, args.check)


if __name__ == "__main__":
    main()
