# tng_planck2015_class

IllustrisTNG's published cosmology (Planck 2015) computed with CLASS, massless neutrinos (as TNG's
simulations assumed): Omega_m = 0.3089 (Omega_b 0.0486, Omega_cdm 0.2603), Omega_Lambda = 0.6911,
h = 0.6774, n_s = 0.9667, sigma_8 = 0.8159, N_ur = 3.046, no massive species.

- `CLASS.ini`: A_s = 2.066167e-9, calibrated so that CLASS gives sigma8 = 0.8159 (CLASS .out:
  "sigma8=0.8159 for total matter"). Calibration: a trial run with A_s = 2.1e-9 gave sigma8 = 0.822553,
  and A_s scales as sigma8^2.
- Run with `~/class_public/class` (abacusorg fork, commit 6cf8e384) and `../abacus_base.pre`.
- `CLASS_power`: z = 1 matter P(k) (CLASS `z2_pk`; total matter = CDM+baryons since no massive nu),
  `CLASS_transfer`: z = 1 transfer function. Other CLASS outputs (other redshifts, background, C_l,
  .out log) are in /flare/Abacus/helenshao/ICs/tng300_3_wn640/class_tng_planck2015_class/.
- `cosm.def`: from `make_cosm_def.py` (Omega_Smooth = 0, ZD_Pk_file_redshift = 1).

Unlike `../tng_planck2015` (TNG's CAMB table, used for shape only), this spectrum's amplitude is
physical, so ZD_Pk_file_redshift = 1 is used directly. Versus TNG's CAMB table at equal sigma_8 it
differs by up to 2.1% in shape for k > 0.01 h/Mpc (3.2% below); see `../tng_planck2015_nu/README.md`.
Used by the TNG300-3 port runs #9 and #16 (`Simulations/tng300_3_port/`).
