#!/usr/bin/env python3
"""Build Cosmologies/neutrino_grid and util/neutrino_glass.dat from util/neutrino_grid.dat.

neutrino_grid.dat mixes two layouts, each introduced by a '#num ...' header:
  - fixed rows (e.g. FLAMINGO 202-206): numeric A_s and h -> no H0_search, no A_s calibration
  - TBD rows (211-218): h TBD (match global theta_s), sigma8_cb target -> A_s calibration

The glass file keeps only the sigma8_cb-target rows, in the column layout
calibrate_A_s.py expects (column 1 = sigma8_cb).

Uses whitespace-exact TBD magic strings required by H0_search.modify_table:
  h:   'TBD   '
  A_s: ' 2.TBD e-9 '
"""
from __future__ import annotations

from pathlib import Path

UTIL = Path(__file__).resolve().parent
COSMO = UTIL.parent / "Cosmologies"
DAT = UTIL / "neutrino_grid.dat"
OUT = COSMO / "neutrino_grid"
GLASS = UTIL / "neutrino_glass.dat"

HubbleTBD = "TBD   "
AsTBD = " 2.TBD e-9 "

HEADER = """## Neutrino staging table (cosm202-206 FLAMINGO fixed h/A_s; cosm211-218 theta_s + sigma8_cb matched)
## Built from util/neutrino_grid.dat by util/neutrino_grid_to_grid.py. Working copy for H0_search → README.txt.
## Do not confuse with the full emulator_grid / README.md.

| root               | notes                                                                | omega_b | omega_cdm | h      | A_s       | n_s    | alpha_s | N_ur   | N_ncdm | omega_ncdm | w0_fld | wa_fld | sigma8_m | sigma8_cb |
| ------------------ | -----                                                                | ------- | --------- | ------ | --------- | ------ | ------- | ------ | ------ | ---------- |------- | ------ | -------- | --------- |
"""

GLASS_HEADER = """# sigma8_cb targets for A_s calibration, built from util/neutrino_grid.dat
#num  sigma8cb    ochh      ns     obhh      w0      wa     Nur     nrun
"""


def parse(path: Path) -> list[dict]:
    rows = []
    cols = None
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#num"):
            cols = line[1:].split()
            continue
        if line.startswith("#"):
            continue
        data, _, comment = line.partition("#")
        vals = data.split()
        assert cols is not None and len(vals) == len(cols), f"bad row: {raw}"
        row = dict(zip(cols, vals))
        row["comment"] = comment.strip()
        rows.append(row)
    return rows


def notes_for(row: dict) -> str:
    if "A_s" in row:
        text = row["comment"]
    else:
        text = f"{row['comment']}; theta_s matched, sigma8_cb = {row['sigma8,bc']}"
    assert len(text) <= 66, f"notes too long: {text}"
    return text.ljust(66)


def format_row(row: dict) -> str:
    # Keep the .dat number strings verbatim (reformatting would round e.g. obhh 0.022375)
    num = int(row["num"])
    n_ncdm = 1 if float(row["omega_ncdm"]) > 0 else 0
    h = f"{row['h']:<6} " if row["h"] != "TBD" else HubbleTBD
    A_s = f" {row['A_s']:<9} " if "A_s" in row else AsTBD
    return (
        f"| abacus_cosm{num:03d}     | {notes_for(row)} | {row['obhh']:<7} | "
        f"{row['ochh']:<7}   | {h}|{A_s}| {row['ns']:<6} | "
        f"{row['nrun']:<5}   | {row['Nur']:<6} | {n_ncdm}      | "
        f"{row['omega_ncdm']:<10} | {row['w0']:<6} | {row['wa']:<6} | \n"
    )


def main() -> None:
    rows = parse(DAT)
    OUT.write_text(HEADER + "".join(format_row(r) for r in rows))
    print(f"wrote {OUT} ({len(rows)} cosmologies)")

    glass = [r for r in rows if "sigma8,bc" in r]
    GLASS.write_text(
        GLASS_HEADER
        + "".join(
            f"{r['num']}  {r['sigma8,bc']}   {r['ochh']}   {r['ns']}   {r['obhh']}  "
            f"{r['w0']}  {r['wa']}  {r['Nur']}   {r['nrun']}\n"
            for r in glass
        )
    )
    print(f"wrote {GLASS} ({len(glass)} sigma8_cb targets)")


if __name__ == "__main__":
    main()
