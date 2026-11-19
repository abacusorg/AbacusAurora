# tng_planck2015_nu

IllustrisTNG cosmology as reconstructed by Ralf Konietzka with one 0.06 eV massive neutrino. The CAMB
settings behind TNG's P(k) table were not recorded; Ralf found these parameters reproduce the table to
sub-percent: Omega_m = 0.3089 (Omega_b 0.0486, Omega_cdm 0.2589, Omega_nu 0.0014), Omega_Lambda = 0.6911,
h = 0.6774, n_s = 0.9667, sigma_8 = 0.8159, sum m_nu = 0.06 eV (1 massive species).

- `CLASS.ini`: AbacusSummit neutrino convention (N_ncdm = 1, omega_ncdm = 0.00064420, N_ur = 2.0328);
  Omega_cdm = 0.2588961 so that Omega_m = 0.3089 exactly. A_s = 2.140778e-9 calibrated so that
  sigma_8 of total matter = 0.8159 (CLASS: sigma8_m = 0.8159, sigma8_cb = 0.81937).
- Run with `~/class_public/class` (abacusorg fork, commit 6cf8e384) and `../abacus_base.pre`.
- `CLASS_power`: z = 1 CDM+baryon P(k) (CLASS `z2_pk_cb`), `CLASS_transfer`: z = 1 transfer function.
  Other CLASS outputs (incl. z = 0 total-matter P(k) and the .out log) are in
  /flare/Abacus/helenshao/ICs/tng300_3_wn640/class_tng_planck2015_nu/.
- `cosm.def`: from `make_cosm_def.py` (Omega_Smooth = 0.001404, ZD_Pk_file_redshift = 1).

Check against TNG's CAMB table (`../tng_planck2015/TNG_power_z0`), both at sigma8_m = 0.8159, z = 0 total matter:
P_table/P_CLASS = 0.995-0.996 for k < 0.01 h/Mpc and 0.996-1.003 for 0.01 < k < 50 h/Mpc (max deviation 0.43%).
The same cosmology with massless neutrinos deviates by up to 2.1% for k > 0.01 (3.2% for k < 0.01),
so the 0.06 eV neutrino is needed to reproduce the table's shape.
