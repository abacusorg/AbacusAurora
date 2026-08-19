#!/usr/bin/env python3
"""Build Cosmologies/desi_secondaries_grid from util/desi_secondaries.dat.

Also appends the same TBD rows to Cosmologies/emulator_grid if not already present.

Uses whitespace-exact TBD magic strings required by H0_search.modify_table:
  h:   'TBD   '
  A_s: ' 2.TBD e-9 '
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

UTIL = Path(__file__).resolve().parent
COSMO = UTIL.parent / "Cosmologies"
DAT = UTIL / "desi_secondaries.dat"
OUT = COSMO / "desi_secondaries_grid"
EMULATOR_GRID = COSMO / "emulator_grid"

# Exact H0_search magic strings (do not retype padding)
HubbleTBD = "TBD   "
AsTBD = " 2.TBD e-9 "

HEADER = """## DESI secondaries staging table (cosm200/201/210 only)
## Built from util/desi_secondaries.dat. Working copy for H0_search → README.txt.
## Do not confuse with the full emulator_grid / README.md.

| root               | notes                                                                | omega_b | omega_cdm | h      | A_s       | n_s    | alpha_s | N_ur   | N_ncdm | omega_ncdm | w0_fld | wa_fld | sigma8_m | sigma8_cb |
| ------------------ | -----                                                                | ------- | --------- | ------ | --------- | ------ | ------- | ------ | ------ | ---------- |------- | ------ | -------- | --------- |
"""

NOTES = {
    200: "DESI DR2+CMB w0wa best-fit",
    201: "DESI DR2+CMB LCDM high-tau",
    210: "DESI DR2+CMB LCDM",
}


def format_row(num: int, sigma8cb, ochh, ns, obhh, w0, wa, Nur, nrun) -> str:
    root = f"abacus_cosm{num:03d}"
    notes = NOTES.get(num, "DESI secondary").ljust(66)[:66]
    # Column formatting mirrors Summit emulator_grid TBD rows
    return (
        f"| {root:<18} | {notes} | {obhh:7.5f} | {ochh:7.4f}   | "
        f"{HubbleTBD}|{AsTBD}| {ns:6.4f} | {nrun:5.3f}   | {Nur:6.4f} | "
        f"1      | 0.00064420 | {w0:5.3f} | {wa:5.3f} | \n"
    )


def main() -> None:
    arr = np.loadtxt(DAT)
    if arr.ndim == 1:
        arr = arr.reshape(1, -1)

    rows = []
    for row in arr:
        num = int(row[0])
        rows.append(
            format_row(
                num,
                row[1],
                row[2],
                row[3],
                row[4],
                row[5],
                row[6],
                row[7],
                row[8],
            )
        )

    OUT.write_text(HEADER + "".join(rows))
    print(f"wrote {OUT} ({len(rows)} cosmologies)")

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
    main()
