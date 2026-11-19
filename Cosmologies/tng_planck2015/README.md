# tng_planck2015

IllustrisTNG cosmology (Planck 2015): Omega_m = 0.3089, Omega_b = 0.0486, Omega_cdm = 0.2603,
Omega_Lambda = 0.6911, h = 0.6774, n_s = 0.9667, sigma_8 = 0.8159, no massive neutrinos.

- `TNG_power_z0`: TNG's CAMB matter power spectrum at z = 0, as received from Ralf Konietzka
  (`camb_24849900_matterpower_z0.dat`). Columns: k [h/Mpc], P [(Mpc/h)^3], 808 rows,
  k = 1e-4 .. 1022 h/Mpc. Units verified: peak at k = 0.016 h/Mpc, low-k slope 0.966 = n_s.
  Its own sigma_8 is 0.6766, not TNG's 0.8159; the exact CAMB settings that made it are not recorded.
- `TNG_power_z1`: the spectrum used by Abacus. Made by `make_z1_table.py`: TNG_power_z0 rescaled to
  sigma_8 = 0.8159, then by D(1)/D(0) = 0.6087749 from `abacus.cosmo` (the growth function
  Abacus uses for ZD_Pk_sigma_ratio), so sigma_8(z=1) = 0.4967.
  With no neutrinos the growth is scale independent, so this equals using the z = 0 table with
  sigma_8 = 0.8159 (what N-GenIC did).
- `cosm.def`: written by hand (no CLASS.ini, so make_cosm_def.py does not apply). Uses
  `ZD_Pk_file_redshift = 1.0`, as the standard Abacus cosmologies do.
