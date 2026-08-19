#!/usr/bin/env python3
"""Redo A_s calibration + full CLASS for cosmologies that still have dummy A_s.

Does not rerun H0_search. Leaves cosm 220-225 and 230-232 alone.
Log: redirect stdout, e.g.
  python repair_core4_as.py > core4_recalib_233_261.log 2>&1
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

UTIL = Path(__file__).resolve().parent
COSMO = UTIL.parent / "Cosmologies"
CLASS = Path.home() / "class_public" / "class"
MAKE_DEF = COSMO / "make_cosm_def.py"
AS_DUMMY = 2.00001e-9
DEFAULT_COSMS = list(range(233, 262))


def _run(cmd: str, cwd: Path) -> None:
    print(cmd, flush=True)
    r = subprocess.run(cmd, shell=True, cwd=cwd)
    if r.returncode != 0:
        raise SystemExit(f"command failed ({r.returncode}): {cmd}")


def parse_ini(path: Path) -> dict[str, str]:
    params = {}
    notes = ""
    for line in path.read_text().splitlines():
        s = line.strip()
        if s.startswith("#"):
            notes = s.lstrip("# ").removeprefix("With A_s calibration, ").strip()
            continue
        if not s or "=" not in s:
            continue
        name, val = re.split(r"\s*=\s*", s, maxsplit=1)
        params[name.strip()] = val.strip()
    params["_notes"] = notes
    return params


def write_ini(path: Path, params: dict[str, str], *, calib: bool, a_s: str) -> None:
    notes = params.get("_notes", "")
    tag = "With A_s calibration, " if calib else ""
    order = [
        "root",
        "omega_b",
        "omega_cdm",
        "h",
        "A_s",
        "n_s",
        "alpha_s",
        "N_ur",
        "N_ncdm",
        "omega_ncdm",
        "w0_fld",
        "wa_fld",
    ]
    lines = [f"root = {params['root'] if params['root'].endswith('.') else params['root'] + '.'}"]
    lines.append(f"# {tag}{notes}")
    for k in order:
        if k == "root":
            continue
        val = f"{a_s}" if k == "A_s" else params[k]
        lines.append(f"{k} = {val}")
    path.write_text("\n".join(lines) + "\n")


def reset_readme_as(root: str) -> None:
    """Set A_s back to the TBD sentinel so calibrate_A_s rescales from dummy."""
    readme = COSMO / "README.txt"
    out = []
    found = False
    for line in readme.read_text().splitlines(keepends=True):
        if root in line and line.lstrip().startswith("|"):
            parts = line.rstrip("\n").split("|")
            # | root | notes | ob | oc | h | As | ...
            # index 6 is A_s (0 is leading empty)
            if len(parts) < 7:
                raise SystemExit(f"README row too short for {root}: {line!r}")
            parts[6] = f" {AS_DUMMY:.5e}"
            line = "|".join(parts)
            if not line.endswith("\n"):
                line += "\n"
            found = True
        out.append(line if line.endswith("\n") else line + "\n")
    if not found:
        raise SystemExit(f"no README.txt row for {root}")
    readme.write_text("".join(out))


def repair_one(n: int) -> None:
    root = f"abacus_cosm{n:03d}"
    d = COSMO / root
    if not d.is_dir():
        raise SystemExit(f"missing {d}")
    print(
        f"\n=== {root} {__import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat()} ===",
        flush=True,
    )

    src_ini = d / "CLASS.ini"
    if not src_ini.is_file():
        raise SystemExit(f"missing {src_ini}")
    params = parse_ini(src_ini)
    params["root"] = root + "."

    work_ini = d / f"{root}.ini"
    write_ini(work_ini, params, calib=True, a_s=f"{AS_DUMMY:.5e}")
    reset_readme_as(root)

    _run(
        f"{CLASS} {work_ini.name} ../abacus_base_fast.pre > {root}.out",
        cwd=d,
    )
    os.environ["ABACUS_GLASS_DAT"] = "emulator_core4.dat"
    _run(f"python calibrate_A_s.py {root} 1", cwd=UTIL)

    # Pick calibrated A_s from README and rewrite ini for the full run.
    a_s = None
    for line in (COSMO / "README.txt").read_text().splitlines():
        if root in line and line.lstrip().startswith("|"):
            cols = [p.strip() for p in line.strip().strip("|").split("|")]
            a_s = cols[5]
            break
    if a_s is None or abs(float(a_s) - AS_DUMMY) < 1e-16:
        raise SystemExit(f"calibrate_A_s did not update A_s for {root} (got {a_s})")
    write_ini(work_ini, params, calib=False, a_s=a_s)

    _run(
        f"{CLASS} {work_ini.name} ../abacus_base.pre > {root}.out",
        cwd=d,
    )
    _run(f"python write_s8.py {root}", cwd=UTIL)
    _run(f"python {MAKE_DEF} {d}", cwd=UTIL)
    print(f"=== done {root} A_s={a_s} ===", flush=True)


def main(only: list[int] | None) -> None:
    if not CLASS.is_file():
        raise SystemExit(f"missing CLASS binary {CLASS}")
    cosms = only or DEFAULT_COSMS
    os.chdir(UTIL)
    for n in cosms:
        repair_one(n)
    _run(
        "python merge_readme_txt_to_md.py --csv ../Cosmologies/cosmologies.csv",
        cwd=UTIL,
    )
    print("all requested cosms finished; README.md / cosmologies.csv updated", flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--only",
        nargs="+",
        type=int,
        default=None,
        help="subset (default: 233-261)",
    )
    main(only=p.parse_args().only)
