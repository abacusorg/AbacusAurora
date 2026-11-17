#!/usr/bin/env python3
"""Generate FLAMINGO-matched linear inputs for the FLAMINGO DMO boxes (see FLAMINGO_MATCHING.md), 2026-11-17.

For each FLAMINGO cosmology this makes its registered AbacusAurora directory Cosmologies/abacus_cosm20N/ (LS8, which has no
registered number, goes to FLAMINGO_cosm/flamingo_LS8/; refuses to touch an existing directory) with
  CLASS.ini        cosmology in AbacusAurora form (omega_b, omega_cdm, h, A_s, n_s, N_ur, N_ncdm, omega_ncdm, deg_ncdm, w0/wa)
  <root>.*         CLASS output of  ~/class_public/class <root>.ini ../flamingo_prod.pre   (AbacusAurora's CLASS v2.9.0)
  CLASS_power      = <root>.z2_pk_cb.dat (root = directory name) (P_cb, z = 1),  CLASS_transfer = <root>.z2_tk.dat
  cosm.def         from Cosmologies/make_cosm_def.py
  validate/        the same cosmology in exactly the form FLAMINGO's monofonIC plugin passed it (Omega_b, Omega_cdm, m_ncdm, deg_ncdm)
                   run with the production CLASS v2.9.4 (~/class_ohahn_v294) + the plugin precision block; validation.txt compares.
Parameters: h, Omega_cdm, Omega_b, N_ur, neutrinos from each box's SWIFT yml (production_ymls/); A_s, n_s from Schaye et al. 2023
Table 4 (PlanckNu0p48Fix: assumed = Planck/PlanckNu0p24Fix, checked through sigma8 = 0.709).
omega_ncdm = deg * m / 93.13858 eV (CLASS's m_i/omega_i for T_ncdm = 0.71611, printed in the CLASS log).
Usage: python3 make_flamingo_cosmologies.py [label ...]     (default: all)
"""
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from scipy.interpolate import CubicSpline

HERE = Path(__file__).resolve().parent
CLASS_AURORA = Path.home() / "class_public" / "class"
CLASS_PROD = Path.home() / "class_ohahn_v294" / "class"
PRE = HERE / "flamingo_prod.pre"
MONO_BLOCK = HERE / "class_version_precision_tests" / "mono_prod.inc"
M_OVER_OMEGA = 93.13858  # eV

# label: (abacus counterpart, FLAMINGO DMO box, h, Omega_cdm, Omega_b, N_ur, deg, m_each_eV, A_s, n_s, sigma8_paper)
COSMO = {
    "D3A": ("c207", "L1_m9_DMO", 0.681, 0.256011, 0.0486, 2.0308, 1, 0.06, 2.099e-9, 0.967, 0.807),
    "Planck": ("c202", "Planck_DMO", 0.6732, 0.265029, 0.04939, 2.0308, 1, 0.06, 2.101e-9, 0.966, 0.812),
    "PlanckNu0p12Var": ("c203", "PlanckNu0p12Var_DMO", 0.6727, 0.263183, 0.04957, 0.00441, 3, 0.04, 2.113e-9, 0.967, 0.800),
    "PlanckNu0p24Fix": ("c204", "PlanckNu0p24Fix_DMO", 0.6732, 0.260764, 0.04939, 0.00441, 3, 0.08, 2.101e-9, 0.966, 0.769),
    "PlanckNu0p48Fix": ("c205", "PlanckNu0p48Fix_DMO", 0.6732, 0.255079, 0.04939, 0.00441, 3, 0.16, 2.101e-9, 0.966, 0.709),
    "PlanckNu0p24Var": ("c206", "PlanckNu0p24Var_DMO", 0.6623, 0.271416, 0.05101, 0.00441, 3, 0.08, 2.109e-9, 0.968, 0.772),
    "LS8": ("none", "LS8_DMO", 0.682, 0.25631499, 0.0473, 2.0308, 1, 0.06, 1.836e-9, 0.965, 0.760),
}


def outdir(label):
    ab = COSMO[label][0]
    return HERE.parent / f"abacus_cosm{ab[1:]}" if ab != "none" else HERE / f"flamingo_{label}"


def class_ini(label):
    ab, box, h, oc, ob, nur, deg, m, a_s, n_s, s8 = COSMO[label]
    on = deg * m / M_OVER_OMEGA
    root = outdir(label).name
    return (f"root = {root}.\n"
            f"# FLAMINGO {label} ({box}). FLAMINGO-matched linear input, 2026-11-17 (FLAMINGO_cosm/FLAMINGO_MATCHING.md); the old standard-pipeline version is in obsolete_FLAMINGO_v1/.\n"
            f"# yml: h = {h}, Omega_cdm = {oc}, Omega_b = {ob}, N_ur = {nur}, {deg} x {m} eV; Table 4: A_s = {a_s}, n_s = {n_s}, sigma8 = {s8}.\n"
            f"# Run: ~/class_public/class {root}.ini <FLAMINGO_cosm>/flamingo_prod.pre   (not abacus_base.pre)\n"
            f"omega_b = {ob * h * h:.10f}\n"
            f"omega_cdm = {oc * h * h:.10f}\n"
            f"h = {h}\n"
            f"A_s = {a_s:.4e}\n"
            f"n_s = {n_s}\n"
            f"alpha_s = 0.0\n"
            f"N_ur = {nur}\n"
            f"N_ncdm = 1.0\n"
            f"omega_ncdm = {on:.12f}\n"
            f"deg_ncdm = {deg}\n"
            f"w0_fld = -1.0\n"
            f"wa_fld = 0.0\n")


def prod_ini(label):
    ab, box, h, oc, ob, nur, deg, m, a_s, n_s, s8 = COSMO[label]
    return (f"root = prod_{label}.\n"
            f"# exactly as monofonIC's 3FA_CLASS plugin passes it (CLASS v2.9.4), outputs at z = 1 only\n"
            f"gauge = synchronous\nh = {h}\nOmega_b = {ob}\nOmega_cdm = {oc}\nOmega_k = 0\nOmega_fld = 0\nOmega_scf = 0\n"
            f"N_ur = {nur}\nN_ncdm = 1\nm_ncdm = {m}\ndeg_ncdm = {deg}\nP_k_ini type = analytic_Pk\nA_s = {a_s:.4e}\nn_s = {n_s}\n"
            f"alpha_s = 0\nT_cmb = 2.7255\nYHe = 0.245421\nreio_parametrization = reio_none\n"
            f"k_per_decade_for_pk = 100\nk_per_decade_for_bao = 100\n"
            + MONO_BLOCK.read_text() +
            "output = mPk,dTk\nP_k_max_h/Mpc = 50.\nz_pk = 1.0\nheaders = yes\nformat = camb\nwrite parameters = yes\nbackground_verbose = 1\n")


def run(cmd, cwd, log):
    env = dict(os.environ, OMP_NUM_THREADS="8")
    with open(cwd / log, "w") as f:
        r = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, env=env)
    if r.returncode:
        raise RuntimeError(f"{cmd} in {cwd} failed (rc={r.returncode}); see {log}")


def sigma8(k, p):
    x = k * 8
    w = 3 * (np.sin(x) - x * np.cos(x)) / x**3
    return np.sqrt(np.trapz(k**3 * p * w**2 / (2 * np.pi**2), np.log(k)))


def make(label):
    d = outdir(label)
    r = d.name
    if d.exists():
        return f"{label}: {d} exists; skipped"
    d.mkdir()
    (d / "CLASS.ini").write_text(class_ini(label))
    shutil.copy(d / "CLASS.ini", d / f"{r}.ini")
    run([str(CLASS_AURORA), f"{r}.ini", str(PRE)], d, f"{r}.out")
    shutil.copy(d / f"{r}.z2_pk_cb.dat", d / "CLASS_power")
    shutil.copy(d / f"{r}.z2_tk.dat", d / "CLASS_transfer")
    v = d / "validate"
    v.mkdir()
    (v / f"prod_{label}.ini").write_text(prod_ini(label))
    run([str(CLASS_PROD), f"prod_{label}.ini"], v, f"prod_{label}.out")
    # compare
    a, b = np.loadtxt(d / "CLASS_power"), np.loadtxt(v / f"prod_{label}.pk_cb.dat")
    k = np.exp(np.linspace(np.log(0.005), np.log(10), 3000))
    sa, sb = (np.exp(CubicSpline(np.log(x[:, 0]), np.log(x[:, 1]))(np.log(k))) for x in (a, b))
    dev = np.max(np.abs(sa / sb - 1))
    tot = np.loadtxt(d / f"{r}.z1_pk.dat")  # z = 0 total matter
    s8 = sigma8(tot[:, 0], tot[:, 1])
    neff = [l.strip() for l in open(d / f"{r}.out") if "total N_eff" in l]
    lines = [f"{label}: pipeline (~/class_public + flamingo_prod.pre, omega_* form) vs production form (CLASS v2.9.4, m_ncdm form), z = 1 P_cb:",
             f"  max |P/P_prod - 1| (k = 0.005-10 h/Mpc, spline) = {dev:.2e}",
             f"  sigma8 (total matter, z = 0) = {s8:.4f}   (paper Table 4: {COSMO[label][10]})",
             f"  {neff[0] if neff else 'N_eff line not found'}"]
    (d / "validation.txt").write_text("\n".join(lines) + "\n")
    return "\n".join(lines)


def main():
    labels = sys.argv[1:] or list(COSMO)
    for x in (CLASS_AURORA, CLASS_PROD, PRE, MONO_BLOCK):
        if not x.exists():
            raise SystemExit(f"missing {x}")
    with ThreadPoolExecutor(max_workers=len(labels)) as ex:
        for out in ex.map(make, labels):
            print(out, flush=True)
    for label in labels:
        d = outdir(label)
        if (d / "cosm.def").exists():
            continue
        subprocess.run([sys.executable, "make_cosm_def.py", str(d.relative_to(HERE.parent))], cwd=HERE.parent, check=True)


if __name__ == "__main__":
    main()
