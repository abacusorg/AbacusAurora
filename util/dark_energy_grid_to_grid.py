#!/usr/bin/env python3
"""Build Cosmologies/dark_energy_grid from util/dark_energy_grid.dat.

Standard | table (no theta column). TBD h/A_s; empty sigma8 columns.
The last .dat column is a theta_s *factor* relative to c000 theta0, so run with
run_class --per-cosm-theta --glass dark_energy_grid.dat (or run_class_one.py h).
dark_energy_grid.dat is also the glass for A_s calibration (column 1 = sigma8_cb).

Unlike emulator_core4_to_grid.py, this does not touch Cosmologies/emulator_grid.

Uses whitespace-exact TBD magic strings required by H0_search.modify_table:
  h:   'TBD   '
  A_s: ' 2.TBD e-9 '
"""
from __future__ import annotations

from pathlib import Path

UTIL = Path(__file__).resolve().parent
COSMO = UTIL.parent / "Cosmologies"
DAT = UTIL / "dark_energy_grid.dat"
OUT = COSMO / "dark_energy_grid"

HubbleTBD = "TBD   "
AsTBD = " 2.TBD e-9 "

COLS = ["num", "sigma8cb", "ochh", "ns", "obhh", "w0", "wa", "Nur", "nrun", "theta_s"]

HEADER = """## Dark energy staging table (cosm270-298: w0wa grid, plus derivatives around c200)
## Built from util/dark_energy_grid.dat by util/dark_energy_grid_to_grid.py. Working copy for H0_search → README.txt.
## theta_s in .dat is a factor; use --per-cosm-theta with --glass dark_energy_grid.dat.
## Do not confuse with the full emulator_grid / README.md.

| root               | notes                                                                | omega_b | omega_cdm | h      | A_s       | n_s    | alpha_s | N_ur   | N_ncdm | omega_ncdm | w0_fld | wa_fld | sigma8_m | sigma8_cb |
| ------------------ | -----                                                                | ------- | --------- | ------ | --------- | ------ | ------- | ------ | ------ | ---------- |------- | ------ | -------- | --------- |
"""


def parse(path: Path) -> list[dict]:
    rows = []
    for raw in path.read_text().splitlines():
        data = raw.partition("#")[0].split()
        if not data:
            continue
        assert len(data) == len(COLS), f"bad row: {raw}"
        rows.append(dict(zip(COLS, data)))
    return rows


def format_row(row: dict) -> str:
    # Keep the .dat number strings verbatim (reformatting could round them)
    num = int(row["num"])
    notes = f"dark energy w0={row['w0']} wa={row['wa']}; theta_s factor={row['theta_s']}"
    assert len(notes) <= 66, f"notes too long: {notes}"
    return (
        f"| abacus_cosm{num:03d}     | {notes:<66} | {row['obhh']:<7} | "
        f"{row['ochh']:<7}   | {HubbleTBD}|{AsTBD}| {row['ns']:<6} | "
        f"{row['nrun']:<5}   | {row['Nur']:<6} | 1      | "
        f"0.00064420 | {row['w0']:<6} | {row['wa']:<6} | \n"
    )


def main() -> None:
    rows = parse(DAT)
    nums = [int(r["num"]) for r in rows]
    assert len(set(nums)) == len(nums), f"duplicate cosm numbers in {DAT}"
    OUT.write_text(HEADER + "".join(format_row(r) for r in rows))
    print(f"wrote {OUT} ({len(rows)} cosmologies: {nums[0]}..{nums[-1]})")


if __name__ == "__main__":
    main()
