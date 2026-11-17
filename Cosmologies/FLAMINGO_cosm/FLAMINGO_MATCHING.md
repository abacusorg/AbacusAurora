# Matching AbacusAurora runs to the FLAMINGO production boxes

Written 2026-11-16; updated 2026-11-17 (corrected FLAMINGO inputs now in the registered `Cosmologies/abacus_cosm202`–`207/` (old versions in `Cosmologies/obsolete_FLAMINGO_v1/`), spline-interpolated BAO numbers). This file documents what FLAMINGO actually used for its DMO boxes, how our inputs compare, and which choices to use
for new FLAMINGO-matched Abacus runs. The supporting runs are in `class_version_precision_tests/` (see its README.txt), with the SWIFT
parameter files in `production_ymls/`. The analysis history is in `hackAurora/flamingo_swiftps_check/LOG.md` (2026-11-04 to 2026-11-16).

## 1. Summary and recommendations

**Use AbacusAurora's own CLASS with `FLAMINGO_cosm/flamingo_prod.pre` instead of `abacus_base.pre`:**
```
cd Cosmologies/FLAMINGO_cosm/<name>;  ~/class_public/class <name>.ini ../flamingo_prod.pre
```
This reproduces FLAMINGO's production CLASS P_cb(z = 1) to 1.5e-7 (D3A, tested; §2.5).

| Choice | Use | Why |
| --- | --- | --- |
| Boltzmann code | `~/class_public` (abacusorg/class_public @ 6cf8e384, CLASS v2.9.0, the AbacusAurora standard) | FLAMINGO's monofonIC (3FA_nu_panph @ 0ba5b9d, 2021-11-06) used ohahn/class_public@master, which from 2020-09 to 2023-03 was **CLASS v2.9.4** (7552778f). For P_cb, v2.9.0 and v2.9.4 are identical (2e-8). |
| Settings file | `flamingo_prod.pre` | The production plugin's precision block, verbatim; YHe 0.245421, reio_none, Λ (Omega_fld = 0), T_cmb 2.7255; Abacus-style outputs. |
| Recombination | RECFAST, the CLASS v2.9 default production used; set explicitly in `flamingo_prod.pre` (since 2026-11-17) so each `<root>.parameters.ini` records it (outputs byte-identical to leaving it unset) | `abacus_base.pre`'s `recombination = HyRec` (2011 HyRec) is the main cause of the 0.5% BAO excess (§4). |
| N_ur / neutrinos | Exactly as in each box's SWIFT yml (§3). D3A, Planck, LS8: N_ur = 2.0308 with 1 × 0.06 eV. PlanckNu*: N_ur = 0.00441 with **3 degenerate** species of Σm_ν/3. | N_eff = 3.044 in all FLAMINGO boxes. |
| Cosmological parameters | h, Ω_cdm, Ω_b from the yml (full precision); A_s, n_s from Schaye et al. 2023, Table 4 | §3 |
| Input redshift | z = 1 P_cb, `ZD_Pk_file_redshift = 1` (AbacusAurora convention) | Abacus's growth has no radiation and smooth neutrinos, so the input is exact only at its own redshift. A z = 1 input is exact at late times and about −0.35% (P) at z = 12. FLAMINGO's z = 31 input is exact at z = 31 and +1% by z = 1. |

**For D3A:** `abacus_cosm207_flamingoclass/` (made with the v3.2 wullm fork) differs from the exact production P_cb by ≤ 3e-5 (BAO b = +0.0002). It is fine to keep. The Abacus 1800³ run from it agrees with FLAMINGO m8 to ≤ 0.1% for k ≤ 1 h/Mpc at z = 0.5–3, with b ≈ 0 at every z.

**Corrected inputs (2026-11-17).** `abacus_cosm202`–`206` (Planck and the neutrino variations) do **not** match FLAMINGO (§3.2): wrong neutrino degeneracy, N_ur 2.0328 and rounded h/ω. For PlanckNu0p24Fix the mismatch is −1.7% in P_cb at k ≥ 0.3 h/Mpc. They are left untouched for the existing runs.

The FLAMINGO-matched inputs now occupy the registered AbacusAurora cosmology directories `Cosmologies/abacus_cosm202`–`207/` (same numbers as before, so `neutrino_cosms.csv`, `cosmologies.csv` and `Cosmologies/README.md` still apply; their rows were updated 2026-11-17). LS8 has no registered number and is in `FLAMINGO_cosm/flamingo_LS8/`. The old standard-pipeline versions of c202–c207 are in `Cosmologies/obsolete_FLAMINGO_v1/` and are still used by the completed 1800³/900³ runs. All are made by `make_flamingo_cosmologies.py` (§6):

| Use for FLAMINGO box | Directory (old version) | H0 | Ω_M (incl. ν) | Ω_Smooth | N_ur, ν | σ8 (z = 0) ours / paper |
| --- | --- | --- | --- | --- | --- | --- |
| L1_m*_DMO (D3A) | `abacus_cosm207` (obsolete_FLAMINGO_v1/abacus_cosm207; also supersedes FLAMINGO_cosm/abacus_cosm207_flamingoclass) | 68.1 | 0.306000 | 0.001389 | 2.0308, 1 × 0.06 eV | 0.8069 / 0.807 |
| Planck_DMO | `abacus_cosm202` (obsolete_FLAMINGO_v1/abacus_cosm202) | 67.32 | 0.315840 | 0.001421 | 2.0308, 1 × 0.06 eV | 0.8118 / 0.812 |
| PlanckNu0p12Var_DMO | `abacus_cosm203` (obsolete_FLAMINGO_v1/abacus_cosm203) | 67.27 | 0.315600 | 0.002847 | 0.00441, 3 × 0.04 eV | 0.7990 / 0.800 |
| PlanckNu0p24Fix_DMO | `abacus_cosm204` (obsolete_FLAMINGO_v1/abacus_cosm204) | 67.32 | 0.315840 | 0.005686 | 0.00441, 3 × 0.08 eV | 0.7677 / 0.769 |
| PlanckNu0p48Fix_DMO | `abacus_cosm205` (obsolete_FLAMINGO_v1/abacus_cosm205) | 67.32 | 0.315841 | 0.011372 | 0.00441, 3 × 0.16 eV | 0.7086 / 0.709 |
| PlanckNu0p24Var_DMO | `abacus_cosm206` (obsolete_FLAMINGO_v1/abacus_cosm206) | 66.23 | 0.328301 | 0.005875 | 0.00441, 3 × 0.08 eV | 0.7706 / 0.772 |
| LS8_DMO | `FLAMINGO_cosm/flamingo_LS8` (new; no registered number) | 68.2 | 0.305000 | 0.001385 | 2.0308, 1 × 0.06 eV | 0.7596 / 0.760 |

Each directory has CLASS.ini, CLASS_power, CLASS_transfer, cosm.def and `validation.txt`.
- **Validation:** each CLASS_power (pipeline form: `~/class_public` + `flamingo_prod.pre`, `omega_*` parameters) agrees with the exact production form (CLASS v2.9.4 with the plugin's `Omega_b`/`Omega_cdm`/`m_ncdm`/`deg_ncdm`, in `validate/`) to ≤ 1e-5 in P_cb(z = 1).
- **N_eff:** 3.044 in all seven.
- **σ8 caveat:** the three-degenerate-ν boxes come out 0.06–0.18% below the paper's σ8 (§7).
- **D3A:** the new `abacus_cosm207` agrees with `FLAMINGO_cosm/abacus_cosm207_flamingoclass` to ≤ 3e-5. Use `abacus_cosm207` for new D3A runs, so that all FLAMINGO cosmologies come from one consistent setup.

## 2. What FLAMINGO production did (provenance)

### 2.1 Sources
- **SWIFT parameter files:** downloaded into `production_ymls/` for L1_m9_DMO (D3A), Planck_DMO, PlanckNu0p12Var_DMO, PlanckNu0p24Var_DMO, PlanckNu0p24Fix_DMO, PlanckNu0p48Fix_DMO and LS8_DMO, from
  `https://dataweb.cosma.dur.ac.uk:8443/hdfstream/download/FLAMINGO/L1_m9/<run>/<file>.yml`.
- **IC file header:** `L1_m9_DMO/initial_conditions/FLAMINGO_DES3_M060_L1000_N1800_DMO.hdf5`, group `/ICs_parameters` (`D3A_m9/ICs_parameters_from_server.txt`):
  - monofonIC branch `3FA_nu_panph` @ `0ba5b9d+` (dirty);
  - Transfer Function `3FA_CLASS`;
  - LPT order 3, 1800³ `sc`, PLT off, Mode Fixing 0;
  - Panphasia descriptor `[Panph6,L18,(56034,71400,250000),S1,KK1025,CH-999,Flamino_Gpc1]`;
  - z = 31.
  - The file stores no cosmology values.
- **The production input spectrum:** Willem Elbers's `input_powerspec.txt` / `input_transfer.txt` from the original L1_m9 D3A DMO run (`hackAurora/flamingo_swiftps_check/flamingo_prod_input_spectra/`).
- **The paper:** Schaye et al. 2023, arXiv:2306.04024, §2.4 (ICs) and Table 4 (cosmologies).
- **The monofonIC source:** in `~/monofonic` (commit 0ba5b9d is fetched there).

### 2.2 IC pipeline
1. **CLASS run:** monofonIC calls CLASS through `ClassEngine`, with the §2.3 parameters, and gets transfer functions at z_target = 0 and z_start = 31.
2. **Backscaling:** 3FA (wullm/3fa_wrapper@master) integrates a Newtonian cdm + baryon + ν model with radiation. Its scale-dependent growth factors scale the z = 0 transfers back to z = 31.
3. **Normalization and gauge:** the amplitude is set by A_s (the plugin passes `A_s` if given, else `sigma8`). The ICs are in N-body gauge.
4. **Particle ICs:** 3-fluid 3LPT at z = 31 from Panphasia (partially fixed for (kL)² < 1025, per the paper). Neutrino particles come from fastdf.
5. **SWIFT evolution:** includes radiation and massless neutrinos in the background, and massive-ν particles (`use_delta_f_mesh_only: 1`).

### 2.3 CLASS settings passed by the production plugin (`src/plugins/transfer_3FA_CLASS.cc` @ 0ba5b9d)
```
z_max_pk = max(zstart, ztarget, 199);  P_k_max_h/Mpc = max(2, kmax);  output = dTk,vTk;  extra metric transfer functions = yes
gauge = synchronous   (a second engine call adds "Nbody gauge transfer functions = yes")
h, Omega_b, Omega_cdm (= Omega_c), Omega_k = 0, Omega_fld = 0, Omega_scf = 0, N_ur, N_ncdm, m_ncdm (comma list)
P_k_ini type = analytic_Pk;  A_s (or sigma8);  n_s;  alpha_s = 0;  T_cmb;  YHe;  reio_parametrization = reio_none
k_per_decade_for_pk = 100;  k_per_decade_for_bao = 100;  compute damping scale = yes
tol_perturb_integration = 1e-8;  tol_background_integration = 1e-9
hyper_flat_approximation_nu = 7000;  transfer_neglect_delta_k_S_t0/t1/t2/e = 0.17/0.05/0.17/0.13;  delta_l_max = 1000
```
- **Recombination:** not set. CLASS v2.9.4's default is RECFAST (`source/input.c`: `pth->recombination=recfast`).
- **Names:** all of these are v2-era parameter names, and CLASS v2.9.4 reads every one (empty `unused_parameters`).
- **YHe:** comes from the monofonIC conf. Willem's FLAMINGO conf template and monofonIC's default parameter set both use **0.245421**. The production conf itself is not public, so this value is an assumption (§7).

### 2.4 Which CLASS
- **monofonIC dependencies:** at 0ba5b9d, `external/class.cmake` points at `https://github.com/ohahn/class_public.git`, `GIT_TAG master`.
- **What master was in November 2021:** the **first-parent** history of master shows it at `7552778f` (Oliver Hahn, 2020-09-07, `_VERSION_ "v2.9.4"`) from September 2020 until a 2023-03-15 merge of upstream v3.2.0. So the production build (November 2021) got CLASS **v2.9.4**: upstream v2.9.4 plus Hahn's ClassEngine/N-body-gauge commits.
  - A plain `git rev-list --before=2021-11-06 master` returns upstream's af4e589 (v3.1.0). That commit is reachable only through the 2023 merge, so it is the wrong answer.
- **Local builds** (gcc, `make class`):
  - `~/class_ohahn_v294`: worktree at 7552778f, the production CLASS.
  - `~/class_ohahn`: master checked out at af4e589 (v3.1.0), kept for the comparisons in §4.

### 2.5 Checks
`input_powerspec.txt` is in monofonIC's Fourier convention, P_mono = P/(2π)³ (σ² = 4π∫k²P W² dk), so multiply by (2π)³. Column `P_dtot(k, a=1/32)` is P_cb.

| Comparison | Result |
| --- | --- |
| σ8_cb(z = 31): Willem vs production CLASS v2.9.4 (A_s 2.099e-9) | 0.032815 vs 0.032812 (0.01%) |
| Willem / CLASS v2.9.4 P_cb(z = 31) | smooth, ≤ 2.4e-4 for k = 0.02–0.4 and ≈ +2e-4 up to k = 10 h/Mpc; +0.12% at k = 0.01, +0.37% at 0.005 (3FA/N-body-gauge large scales) |
| BAO b, Willem / CLASS z = 31 | +0.0000 ± 0.0001: no BAO mismatch |
| BAO b, Willem / CLASS z = 0 shape | −0.0005 ± 0.0015 (the shape ratio rises smoothly by ~1e-3 at k < 0.1 from scale-dependent ν growth, z = 31 → 0) |
| Pipeline form (`~/class_public` + CLASS.ini with omega_* + `flamingo_prod.pre`) / CLASS v2.9.4 production run, z = 1 | max \|ΔP/P\| = 1.5e-7 (k = 0.01–5) |
| `~/class_public` v2.9.0 with the production block (v29_recfast_mono) / v2.9.4 | max 1.9e-8 |
| CLASS v3.1.0 / v2.9.4 (same block) | max 3.3e-5 (HyRec2020 default; with RECFAST 1.6e-5) |

Plot: `hackAurora/flamingo_swiftps_check/plots/willem_vs_production_class_v294_spline.png` (`plot_willem_vs_production_class.py`).

**Interpolate tabulated spectra with a cubic spline in log P–log k, not linearly.** The tables are coarse relative to the BAO: CLASS has 100 points per decade, Willem's file 231. Linear log-log interpolation cuts the BAO peaks and makes spurious BAO-phased wiggles of up to 6e-4 in ratios of differently sampled tables. The first version of the plot (`..._v294.png`) and the first b values in §4 had this problem; the spline error is 2e-6. Abacus's ZD reader already uses a cubic spline.

Conclusion: the production input is CLASS v2.9.4 (RECFAST) with N_ur = 2.0308, m_ν = 0.06 eV, A_s = 2.099e-9, YHe ≈ 0.2454 and monofonIC
precision, backscaled by 3FA. The A_s, N_ur and shape are confirmed by Willem's file; YHe 0.245421 vs 0.2455 changes P_cb by < 1e-5, so the file cannot pin it down.

## 3. Cosmological parameters

### 3.1 FLAMINGO production values
- **Sources:** h, Ω_cdm, Ω_b, N_ur and the neutrinos are from each box's SWIFT yml; A_s and n_s are from Table 4 of the paper.
- **Neutrino temperature:** all boxes use T_ν0 = 1.9517578 K (CLASS's default T_ncdm = 0.71611).
- **Density definitions:** SWIFT's Ω_m = Ω_cdm + Ω_b excludes neutrinos. The paper's Ω_m (0.306 for D3A) includes them: 0.256011 + 0.0486 + 0.001389.

| FLAMINGO box | h | Ω_cdm | Ω_b | Ω_Λ (yml) | N_ur | massive ν | A_s | n_s | σ8 (paper) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| L1_m*_DMO (D3A) | 0.681 | 0.256011 | 0.0486 | 0.693922 | 2.0308 | 1 × 0.06 eV | 2.099e-9 | 0.967 | 0.807 |
| Planck_DMO | 0.6732 | 0.265029 | 0.04939 | 0.684080 | 2.0308 | 1 × 0.06 eV | 2.101e-9 | 0.966 | 0.812 |
| PlanckNu0p12Var_DMO | 0.6727 | 0.263183 | 0.04957 | 0.684345 | 0.00441 | 3 × 0.04 eV | 2.113e-9 | 0.967 | 0.800 |
| PlanckNu0p24Var_DMO | 0.6623 | 0.271416 | 0.05101 | 0.671644 | 0.00441 | 3 × 0.08 eV | 2.109e-9 | 0.968 | 0.772 |
| PlanckNu0p24Fix_DMO | 0.6732 | 0.260764 | 0.04939 | 0.684105 | 0.00441 | 3 × 0.08 eV | 2.101e-9 | 0.966 | 0.769 |
| PlanckNu0p48Fix_DMO | 0.6732 | 0.255079 | 0.04939 | 0.684105 | 0.00441 | 3 × 0.16 eV | 2.101e-9 (assumed) | 0.966 (assumed) | 0.709 |
| LS8_DMO | 0.682 | 0.25631499 | 0.0473 | 0.694922311 | 2.0308 | 1 × 0.06 eV | 1.836e-9 | 0.965 | 0.760 |

- **N_eff = 3.044 in every box.** With 1 × 0.06 eV, N_ur 2.0308 + 1.0132 gives 3.044. With 3 degenerate species, N_ur 0.00441 + 3.0396 gives 3.044. The paper's text quotes 3.046; the ymls and CLASS give 3.044.
- **PlanckNu0p48Fix:** its row was missing from the table extract I could read. A_s and n_s are assumed equal to PlanckNu0p24Fix ("Fix" = Planck parameters fixed). Confirm them before use.

### 3.2 Comparison with our Cosmologies (`abacus_cosm202`–`207`, `neutrino_cosms.csv`)
Each cell is FLAMINGO / ours. Mismatches are in bold.

| FLAMINGO / ours | h | ω_b | ω_cdm | N_ur | massive ν | n_s |
| --- | --- | --- | --- | --- | --- | --- |
| D3A / c207 | 0.681 / 0.681 | 0.022539 / 0.022539 | 0.118728 / 0.118730 | **2.0308 / 2.0328** | 1 × 0.06 / 1 × 0.06 | 0.967 / 0.967 |
| D3A / c207_flamingoclass | identical | identical | identical | 2.0308 / 2.0308 | identical | identical |
| Planck / c202 | **0.6732 / 0.673** | 0.022383 / 0.022375 | 0.120111 / 0.120100 | **2.0308 / 2.0328** | 1 × 0.06 / 1 × 0.06 | 0.966 / 0.966 |
| PlanckNu0p12Var / c203 | **0.6727 / 0.673** | **0.022432 / 0.022465** | **0.119097 / 0.119400** | **0.00441 / 2.0328** | **3 × 0.04 / 1 × 0.12** | **0.967 / 0.966** |
| PlanckNu0p24Fix / c204 | **0.6732 / 0.673** | 0.022383 / 0.022375 | 0.118178 / 0.118200 | **0.00441 / 2.0328** | **3 × 0.08 / 1 × 0.24** | 0.966 / 0.966 |
| PlanckNu0p48Fix / c205 | **0.6732 / 0.673** | 0.022383 / 0.022375 | 0.115601 / 0.115600 | **0.00441 / 2.0328** | **3 × 0.16 / 1 × 0.48** | 0.966 / 0.966 |
| PlanckNu0p24Var / c206 | **0.6623 / 0.662** | **0.022375 / 0.022350** | **0.119054 / 0.118800** | **0.00441 / 2.0328** | **3 × 0.08 / 1 × 0.24** | 0.968 / 0.968 |
| LS8 / none | 0.682 | 0.022000 | 0.119218 | 2.0308 | 1 × 0.06 | 0.965 |

A_s matches in every row where it is known. The c202–c206 inputs were also made with `abacus_base.pre` (2011 HyRec, pk_ref, YHe = BBN, reio_camb), so they carry the §4 BAO excess as well.

- **Size of the effect:** for PlanckNu0p24Fix, c204-style inputs / FLAMINGO-exact give P_cb(z = 1) − 1 of:
  - +0.96% at k = 0.01;
  - −0.47% at 0.05 and −1.22% at 0.1;
  - −1.70% at 0.3 and −1.73% at 1 h/Mpc.

  This is from `nu24fix_c204style` vs `nu24fix_flamingo`, both with CLASS v3.1 and production precision. It is mostly one heavy neutrino instead of three light ones: a different free-streaming scale, and relativistic energy in N_ur instead of the ncdm species.
- **How to write degenerate neutrinos for `make_cosm_def.py`:** keep `N_ncdm = 1` and add `deg_ncdm = 3`, with `omega_ncdm` = Σm_ν/93.14 eV. CLASS treats `omega_ncdm` as the species total including degeneracy, so `make_cosm_def.py`, which sums `omega_ncdm`, still gets Ω_Smooth right. (FLAMINGO passed `m_ncdm` directly; the pipeline's `omega_ncdm` form reproduced the production D3A P_cb to 1.5e-7.)

## 4. Why AbacusAurora's standard CLASS setup gives larger BAO than FLAMINGO (precision vs version)

Runs: `class_version_precision_tests/`.
- **Parameters:** every run uses identical FLAMINGO D3A parameters (YHe 0.245421, reio_none, N_ur 2.0308, A_s 2.099e-9).
- **What varies:** only the CLASS version, the precision and the recombination code.
- **Measure:** the BAO-template amplitude b of P_cb(z = 1) relative to the production CLASS (`v294_prod`), k = 0.02–0.3, median of 54 fit variants (`hackAurora/flamingo_swiftps_check/bao_wiggle_fit.fit_one`). Spectra are cubic-spline interpolated (`q2fit_spline.py`).

| Run (vs production v2.9.4) | CLASS | precision | recombination | b |
| --- | --- | --- | --- | --- |
| v29_recfast_mono | v2.9.0 (`~/class_public`) | production block | RECFAST | 0.0000 ± 0.0000 (P to 2e-8) |
| v31_prod_recfast | v3.1.0 | production block | RECFAST | 0.0000 ± 0.0000 |
| v31_prod | v3.1.0 | production block (tol not read) | HyRec2020 | +0.0002 ± 0.0000 |
| flamingoclass (wullm v3.2, tol 1e-8, YHe 0.2455) | v3.2.0 | production block | HyRec2020 | +0.0002 ± 0.0000 |
| v29_recfast_pkref | v2.9.0 | v2.9 pk_ref.pre | RECFAST | +0.0013 ± 0.0011 |
| v31_pkref | v3.1.0 | v3.1 pk_ref.pre | HyRec2020 | +0.0015 ± 0.0011 |
| v29_hyrec_mono | v2.9.0 | production block | HyRec (2011) | +0.0033 ± 0.0007 |
| v29_hyrec_pkref | v2.9.0 | v2.9 pk_ref.pre | HyRec (2011) | +0.0045 ± 0.0015 |
| nur2p0308 (c207 setup, N_ur 2.0308) | v2.9.0 | abacus_base.pre | HyRec (2011) | +0.0045 ± 0.0015 |
| c207 (AbacusAurora standard) | v2.9.0 | abacus_base.pre | HyRec (2011) | +0.0046 ± 0.0015 |

Decomposition of c207's b = +0.0046 relative to FLAMINGO production. With linear interpolation it was +0.0053; the difference is the interpolation artefact from c207's finer k table.


| Source | Contribution to b | Evidence |
| --- | --- | --- |
| `recombination = HyRec` in abacus_base.pre (v2.9's bundled 2011 HyRec) vs production's RECFAST | **+0.0033** (70%) | The same at both precisions: +0.0033 (production block), +0.0033 (pk_ref) |
| pk_ref.pre vs production precision | +0.0012 (26%) | The same in v2.9/RECFAST, v2.9/HyRec and v3.1; about 1σ of the fit spread |
| abacus_base.pre's other physics settings (YHe = BBN, reio_camb) and rounded ω | 0.0000 | c207-setup (nur2p0308) vs v29_hyrec_pkref |
| N_ur 2.0328 vs 2.0308 | +0.0002 | c207 vs nur2p0308; the 1800³ N-body pair gives −0.0002 |
| CLASS version (v2.9.0 vs v2.9.4 vs v3.1) | **0.0000** | P_cb identical to 2e-8 (v2.9.x) and 3e-5 (v3.1) |

So the BAO difference comes from the **settings in `abacus_base.pre`, not the CLASS version**:
- **Recombination code (main cause):** HyRec2020 and RECFAST agree with each other to b = 0.0002, so the 2011 HyRec is the outlier.
- **Precision (secondary, at the 1σ level):** `pk_ref.pre` is more converged than the monofonIC settings. Its b = +0.0012 ± 0.0011 suggests FLAMINGO's own inputs may be under-converged at the ~0.1% level in BAO amplitude. That is irrelevant for matching FLAMINGO.

N-body confirmation (1800³, z = 12–1, same noise):
- the N_ur-only pair gives b = −0.0001 to −0.0002;
- the CLASS-setup-only pair gives b = +0.0068 to +0.0072 (nonlinear growth amplifies the linear +0.005);
- with the FLAMINGO-matched input, b vs FLAMINGO m8 = +0.0000 to +0.0004 from z = 12 to 0.5.

## 5. Simulation setup: the 1800³ test setup (`Simulations/FLAMINGO_1800_local/FLAMINGO.par2`, `FLAMINGO_m9.par2`, + `base.def`) vs FLAMINGO L1_m9_DMO

This table is for the 1800³ comparison runs. The NP = 2500³ production setup is §9; it has the same physics choices, softening ℓ/40 and outputs at FLAMINGO's 13 full-particle snapshot redshifts.


| Item | FLAMINGO L1_m9_DMO | AbacusAurora | Status |
| --- | --- | --- | --- |
| Box | 1000 Mpc | BoxSize = 10·H0 = 681 Mpc/h | match |
| Particles | 1800³ CDM(+b) + 1000³ ν (δf on the mesh only) | NP = 1800³ cb; ν as smooth Ω_Smooth, not displaced (ZD_f_cluster = 1 − Ω_Smooth/Ω_M) | deliberate; no ν clustering (matters at k ≲ 0.02) |
| Background | radiation + massless ν + massive ν (yml Ω_Λ = 0.693922) | Ω_DE = 1 − Ω_M = 0.694, no radiation; ν as matter | known: −0.35% in P at z = 12 for a z = 1 input |
| Linear input | CLASS v2.9.4 at z = 0, 3FA-backscaled to z = 31 | CLASS P_cb at z = 1, ZD_Pk_file_redshift = 1, backscaled with Abacus D(z) | use §1/§6 inputs |
| Phases | Panphasia (descriptor above), 1800³ | Zeldovich-MPI reading monofonIC's Panphasia noise slabs (N0 = 2048, GridRes 1800, same descriptor), ZD_CornerModes = 1 | matched (ratio flat to 5e-4 at k < 0.05) |
| IC order / start | 3LPT, 3-fluid, z = 31, no PLT | 2LPT (LagrangianPTOrder = 2) + PLT (ZD_qPLT, target z = 12), z = 99 | deliberate (Abacus standard); ICs agree to ≲ 0.4% at z = 12 |
| Gauge | N-body gauge | synchronous-gauge CLASS P_cb | irrelevant for k > 0.005 h/Mpc |
| Softening | 22.3 ckpc comoving, max 5.7 pkpc (Plummer-equivalent) | ℓ/40 = 9.46 kpc/h (13.9 kpc) proper (ProperSoftening = 1), capped at 0.15ℓ = 56.75 ckpc/h | Abacus softer; m8 comparison agrees to ≤ 0.1% for k ≤ 1 h/Mpc |
| Gravity | FMM + PM (mesh 2048), adaptive MAC ε = 0.001, η = 0.025 | multipole Order 8, NearFieldRadius 2, TimeStepAccel 0.25, TimeStepDlna 0.03 | different codes |
| Spectra | on-the-fly power_cdm (SWIFT folding: 256³, 6 folds × 4, TSC) | snapshots re-measured with `swiftps_estimator.py` (same estimator) | matched |

## 6. Recipe for a new FLAMINGO-matched cosmology
All seven FLAMINGO DMO cosmologies are already done (into `Cosmologies/abacus_cosm202`–`207/` and `FLAMINGO_cosm/flamingo_LS8/`) with `python3 make_flamingo_cosmologies.py [label ...]` (in `FLAMINGO_cosm/`). The script holds the parameter table (§3.1) and does the steps below. It skips any existing directory, and writes the production-form cross-check in `validate/` plus `validation.txt`. For a new FLAMINGO cosmology, add a row to its `COSMO` table. By hand:

1. **Make the directory:** `Cosmologies/FLAMINGO_cosm/<name>/` (never overwrite existing ones).
2. **Write `CLASS.ini`** (cosmology only, in the AbacusAurora form that `make_cosm_def.py` reads):
   ```
   root = <name>.
   omega_b = <Ω_b h²>            # from the yml, full precision
   omega_cdm = <Ω_cdm h²>
   h = <yml h>
   A_s = <Table 4>
   n_s = <Table 4>
   alpha_s = 0.0
   N_ur = <yml N_ur>              # 2.0308, or 0.00441 for the PlanckNu boxes
   N_ncdm = 1.0
   omega_ncdm = <Σm_ν / 93.14>    # species total
   deg_ncdm = <1 or 3>            # 3 for the PlanckNu boxes
   w0_fld = -1.0
   wa_fld = 0.0
   ```
   Then `cp CLASS.ini <name>.ini`, as the pipeline does.
3. **Run CLASS:** `~/class_public/class <name>.ini ../flamingo_prod.pre` (about 1 minute). Check the log: `total N_eff = 3.044`. The `unused_parameters` file should list only w0_fld, wa_fld and write warnings.
4. **Copy the outputs:** `<name>.z2_pk_cb.dat` → `CLASS_power` and `<name>.z2_tk.dat` → `CLASS_transfer` (z = 1).
5. **Make cosm.def:** `python3 make_cosm_def.py FLAMINGO_cosm/<name>` from `Cosmologies/`. Check Ω_M (incl. ν) and Ω_Smooth against §3.1.
6. **Use it:** `#include` it from the par2 (ZD_Pk_file_redshift = 1 comes from cosm.def).

## 7. Open items
- **σ8 of the degenerate-ν boxes:** PlanckNu0p12Var, PlanckNu0p24Fix, PlanckNu0p24Var and PlanckNu0p48Fix come out 0.06–0.18% below the paper's σ8 (0.7990 vs 0.800, 0.7677 vs 0.769, 0.7706 vs 0.772, 0.7086 vs 0.709). D3A, Planck and LS8 match within rounding. That suggests a slightly different A_s (or σ8 definition) for those boxes than the 4-digit Table 4 values. An 0.18% σ8 offset is 0.36% in P. The production monofonIC confs would settle it.
- **Production conf values:** YHe = 0.245421, and A_s/n_s for PlanckNu0p48Fix, are assumptions. Ask Willem for the monofonIC `.conf` files of the production boxes. (YHe 0.2455 vs 0.245421 changes P_cb by < 1e-5, so this is low priority.)
- **Growth outside z ≈ 1:** Abacus's growth lacks radiation. Our z = 1-normalized runs are −0.35% (z = 12), −0.14% (z = 5) and −0.07% (z ≤ 2) in P vs FLAMINGO at k ≈ 0.05–0.1.
- **Existing c202–c206 runs:** any FLAMINGO-matched Abacus runs made from those cosmologies inherit the §3.2 and §4 mismatches.

## 8. File index
- `Cosmologies/abacus_cosm202`–`207/` and `FLAMINGO_cosm/flamingo_LS8/` — **FLAMINGO-matched inputs to use** (§1), made by `make_flamingo_cosmologies.py`.
- `Cosmologies/obsolete_FLAMINGO_v1/abacus_cosm202`–`207/` — the old standard-pipeline versions (README.txt there), kept for the completed 1800³/900³ runs.
- `flamingo_prod.pre` — FLAMINGO production CLASS settings (use instead of abacus_base.pre).
- `abacus_cosm207_flamingoclass/` — D3A input (z = 1) used for the matched 900³/1800³ runs (≤ 3e-5 from production).
- `abacus_cosm207_nur2p0308/` — c207 setup with N_ur 2.0308 (BAO test).
- `abacus_cosm207_flamingoprodv2/` — Willem's z = 31 file × (2π)³ (the v1 directory lacks the (2π)³ and must not be used).
- `class_version_precision_tests/` — §2.5 and §4 runs, `q2fit_spline.py` (use this; `q2fit.py` interpolates linearly), README.txt.
- `production_ymls/` — SWIFT ymls of the L1_m9 DMO boxes.
- `D3A_m9/` — production IC header, D3A yml, the 2024 zwindstroom reproduction.
- CLASS builds:
  - `~/class_public` (abacusorg v2.9.0, AbacusAurora standard);
  - `~/class_ohahn_v294` (ohahn 7552778f, v2.9.4 = production);
  - `~/class_ohahn` (af4e589, v3.1.0);
  - `~/class_wullm_dcdm` (v3.2.0 fork).

## 9. Running the FLAMINGO-matched Aurora sims at Flagship mass resolution (NP = 2500³; set up 2026-11-17)
All FLAMINGO-matched production sims use NP = 2500³ in FLAMINGO's 1 Gpc box. The interparticle spacing is 0.2724 Mpc/h for D3A (AuroraFlagship: 0.2713).

| Piece | Path / value |
| --- | --- |
| White noise | `/flare/Abacus/helenshao/ICs/flamingo_panphasia_N4096/noise`: FLAMINGO's descriptor at Panphasia level 11, N0 = 4096 (2049 slabs × 256 MiB). Made by `zeldovich_mpi/neutrino_validation/flamingo_noise_N2500/` (job 9096592, 32 nodes, 30 min, 8.9 TB peak memory); checksums in `noise_sha256.txt`. Same realisation as the N0 = 1024/2048 sets: the large-scale modes are identical, plus smaller-scale modes. |
| Template | `Simulations/FLAMINGO.par2`: NP = 2500**3, CPD = 625 (PPC 64; derivatives `deriv*_625_8_2_8` already exist, they depend only on CPD/Order/NearFieldRadius/DerivativeExpansionRadius, not on NP or box), NumZRanks = 4 (8 × 4 domain on 16 nodes). Outputs at FLAMINGO's 13 full-particle snapshot redshifts from the FLAMINGO website, z = 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, with all particles at z = 0, 0.5, 1.0 and subP8 elsewhere. (`production_ymls/L1_m9_DMO__output_list.txt` lists all 78 SWIFT snapshot times; the 13 are the documented full-particle set.) |
| Per-cosmology par2 | `Simulations/flamingo_nu_N2500/AbacusAurora_FLAMINGO_<label>_N2500.par2` for D3A (c207), Planck (c202), PlanckNu0p12Var (c203), PlanckNu0p24Fix (c204), PlanckNu0p48Fix (c205), PlanckNu0p24Var (c206) and LS8 (cosm.def from `Cosmologies/abacus_cosm20x/`, LS8 from `FLAMINGO_cosm/flamingo_LS8/`; SCR pinned to PTHREAD for the 9575f04 build) |
| Job script | `zeldovich_mpi/neutrino_validation/production/pbs_flamingo.sh`: capacity queue, 16 nodes (the queue maximum), 6 h walltime (halts cleanly and resumes), build 9575f04_zmpi-neutrinos. It sets ZD_EXTERNAL_NOISE_DIR to the N0 = 4096 set (the build's compiled-in default is N0 = 2048) and exports ABACUS_CHECKPOINT_CONTAINERS=0. |
| Submit | `qsub -v SIMNAME=AbacusAurora_FLAMINGO_<label>_N2500 -o $PWD/flamingo_<label>_N2500.pbs.log pbs_flamingo.sh` (the capacity queue runs 2 jobs per user at a time) |
| Expected cost | ~2.5–3 h per sim on 16 nodes (1800³ took 7.0 h on 2 nodes). Outputs are ~0.55 TB per sim: 3 × ~130 GB all-particle + 10 × ~16 GB subP8. |
| Old 1800³ files | The previous `FLAMINGO.par2`, `FLAMINGO_m9/m10*.par2`, `FLAMINGO_nu_c20x.par2`, `smoke_nu256_c202.par2` and `flamingo_nu_v1/` are in `Simulations/FLAMINGO_1800_local/` (local only, includes adjusted). The old job scripts, run directories and logs are in `production/flamingo_1800_local/`. |

All seven par2s parse:
- BoxSize = 1000 Mpc × h;
- softening ℓ/40 = 6.81 kpc/h for D3A, the base.def rule shared with AuroraFlagship (6.78 kpc/h there);
- ZD_Pk_sigma_ratio = D(99)/D(1) and ZD_f_cluster = 1 − Ω_Smooth/Ω_M for each cosmology.

The ZD noise reader keeps the modes of a native 2500³ grid from the N0 = 4096 slabs.
