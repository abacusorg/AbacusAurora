#!/usr/bin/env python3
"""Build Cosmologies/emulator_core4_grid from util/emulator_core4.dat.

Standard | table (no theta column). TBD h/A_s; empty sigma8 columns.
theta_s last column of the .dat is a *factor* relative to c000 theta0;
H0_search --per-cosm-theta applies theta_def = theta0 * factor.

Also appends the same TBD rows to Cosmologies/emulator_grid if not already present.

Uses whitespace-exact TBD magic strings required by H0_search.modify_table:
  h:   'TBD   '
  A_s: ' 2.TBD e-9 '
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

UTIL = Path(__file__).resolve().parent
COSMO = UTIL.parent / "Cosmologies"
DAT = UTIL / "emulator_core4.dat"
OUT = COSMO / "emulator_core4_grid"
EMULATOR_GRID = COSMO / "emulator_grid"

# Exact H0_search magic strings (do not retype padding)
HubbleTBD = "TBD   "
AsTBD = " 2.TBD e-9 "

HEADER = """## Emulator core4.5d staging table (cosm220-225, 230-261)
## Built from util/emulator_core4.dat. Working copy for H0_search → README.txt.
## theta_s in .dat is a factor; use run_class --per-cosm-theta --glass emulator_core4.dat.
## Do not confuse with the full emulator_grid / README.md.

| root               | notes                                                                | omega_b | omega_cdm | h      | A_s       | n_s    | alpha_s | N_ur   | N_ncdm | omega_ncdm | w0_fld | wa_fld | sigma8_m | sigma8_cb |
| ------------------ | -----                                                                | ------- | --------- | ------ | --------- | ------ | ------- | ------ | ------ | ---------- |------- | ------ | -------- | --------- |
"""


def format_row(num: int, ochh, ns, obhh, w0, wa, Nur, nrun, theta_factor) -> str:
    root = f"abacus_cosm{num:03d}"
    notes = f"core4.5d; theta_s factor={theta_factor:.4f}".ljust(66)[:66]
    return (
        f"| {root:<18} | {notes} | {obhh:7.5f} | {ochh:7.4f}   | "
        f"{HubbleTBD}|{AsTBD}| {ns:6.4f} | {nrun:5.3f}   | {Nur:6.4f} | "
        f"1      | 0.00064420 | {w0:5.3f} | {wa:5.3f} | \n"
    )


def main(only: list[int] | None = None, out: Path | None = None) -> None:
    out_path = out or OUT
    arr = np.loadtxt(DAT)
    if arr.ndim == 1:
        arr = arr.reshape(1, -1)
    assert arr.shape[1] >= 10, f"expected >=10 cols in {DAT}, got {arr.shape}"

    only_set = set(only) if only else None
    rows = []
    for row in arr:
        num = int(row[0])
        if only_set is not None and num not in only_set:
            continue
        # cols: num sigma8cb ochh ns obhh w0 wa Nur nrun theta_s(factor)
        rows.append(
            format_row(
                num,
                row[2],
                row[3],
                row[4],
                row[5],
                row[6],
                row[7],
                row[8],
                float(row[9]),
            )
        )

    if only_set is not None and len(rows) != len(only_set):
        found = {int(r.split("|")[1].strip().replace("abacus_cosm", "")) for r in rows}
        missing = sorted(only_set - found)
        raise SystemExit(f"cosm numbers not in {DAT.name}: {missing}")

    out_path.write_text(HEADER + "".join(rows))
    print(f"wrote {out_path} ({len(rows)} cosmologies)")

    # Insert into emulator_grid after the last | abacus_cosm* table row (not EOF)
    eg_lines = EMULATOR_GRID.read_text().splitlines(keepends=True)
    eg_text = "".join(eg_lines)
    to_add = []
    for row in rows:
        root = row.split("|")[1].strip()
        if root not in eg_text:
            to_add.append(row if row.endswith("\n") else row + "\n")
            print(f"will insert {root} after last table row")
        else:
            print(f"emulator_grid already has {root}")
    if to_add:
        last = max(i for i, ln in enumerate(eg_lines) if ln.startswith("| abacus_cosm"))
        new_lines = eg_lines[: last + 1] + to_add + eg_lines[last + 1 :]
        EMULATOR_GRID.write_text("".join(new_lines))
    print(f"emulator_grid inserts: {len(to_add)}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--only",
        nargs="+",
        type=int,
        default=None,
        help="subset of cosm numbers (e.g. pilot: --only 222 230)",
    )
    p.add_argument(
        "--out",
        type=Path,
        default=None,
        help="output staging table path (default: Cosmologies/emulator_core4_grid)",
    )
    ns = p.parse_args()
    main(only=ns.only, out=ns.out)
