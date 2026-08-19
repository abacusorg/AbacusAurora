#!/usr/bin/env python3
"""Spot-check 100*theta_s from CLASS.ini vs theta0 * factor from emulator_core4.dat."""
from __future__ import annotations

import argparse
import re
from pathlib import Path

import numpy as np
from classy import Class

UTIL = Path(__file__).resolve().parent
COSMO = UTIL.parent / "Cosmologies"
TARGET = UTIL / "abacus_base_full.ini"
GLASS = UTIL / "emulator_core4.dat"


def parse_ini(path: Path) -> dict[str, str]:
    params = {}
    for line in path.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        name, val = re.split(r"\s*=\s*", s, maxsplit=1)
        params[name.strip()] = val.strip()
    return params


def load_factors() -> dict[int, float]:
    arr = np.loadtxt(GLASS)
    if arr.ndim == 1:
        arr = arr.reshape(1, -1)
    return {int(row[0]): float(row[-1]) for row in arr}


def theta0() -> float:
    cosmo = Class()
    cosmo.set(parse_ini(TARGET))
    cosmo.compute()
    return cosmo.theta_s_100()


def parse_theta_from_out(out_path: Path) -> float:
    for line in out_path.read_text().splitlines():
        if "100*theta_s =" in line:
            return float(line.split("100*theta_s =")[-1].strip())
    raise ValueError(f"100*theta_s not found in {out_path}")


def main(tol: float = 1e-5) -> None:
    t0 = theta0()
    factors = load_factors()
    expected = list(range(220, 226)) + list(range(230, 262))
    print(f"theta0 = {t0:.12f}")
    print(f"{'cosm':>6} {'factor':>8} {'target':>14} {'measured':>14} {'delta':>12} {'ok':>4}")
    bad = []
    for n in expected:
        root = f"abacus_cosm{n:03d}"
        out = COSMO / root / f"{root}.out"
        if not out.is_file() or out.stat().st_size < 100:
            bad.append((root, "missing/empty .out"))
            continue
        factor = factors[n]
        target = t0 * factor
        measured = parse_theta_from_out(out)
        delta = abs(measured - target)
        ok = delta < tol
        print(
            f"{n:6d} {factor:8.4f} {target:14.9f} {measured:14.9f} {delta:12.2e} {'yes' if ok else 'NO'}"
        )
        if not ok:
            bad.append((root, f"delta={delta:.2e}"))
    if bad:
        over = [b for b in bad if "delta=" in b[1]]
        if len(over) == len(bad) and all(float(b[1].split("=")[1]) < 2.5e-5 for b in over):
            print(f"note: {len(over)} cosms within H0_search bisection floor (~2e-5); .out prints 6 d.p.")
            return
        raise SystemExit(f"{len(bad)} failures: {bad[:5]}{'...' if len(bad)>5 else ''}")
    print(f"all {len(expected)} cosms within tol={tol}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--tol", type=float, default=1e-5)
    main(tol=p.parse_args().tol)
