# tng_planck2015

IllustrisTNG cosmology (Planck 2015): Omega_m = 0.3089, Omega_b = 0.0486, Omega_cdm = 0.2603,
Omega_Lambda = 0.6911, h = 0.6774, n_s = 0.9667, sigma_8 = 0.8159, no massive neutrinos.

- `TNG_power_z0`: TNG's CAMB matter power spectrum at z = 0, as received from Ralf Konietzka
  (`camb_24849900_matterpower_z0.dat`). Columns: k [h/Mpc], P [(Mpc/h)^3], 808 rows,
  k = 1e-4 .. 1022 h/Mpc. Units verified: peak at k = 0.016 h/Mpc, low-k slope 0.966 = n_s.
  Its own sigma_8 is 0.6766, not TNG's 0.8159; the exact CAMB settings that made it are not recorded.
- `TNG_power_z1`: the spectrum Abacus reads. Made by `make_z1_table.py` (see below).
- `cosm.def`: written by hand (no CLASS.ini, so make_cosm_def.py does not apply).

## Why `ZD_Pk_file_redshift = 1` is valid here

`ZD_Pk_file_redshift = z_file` tells Abacus to trust the table's amplitude as the true linear spectrum at
z_file; abacus.py then sets `ZD_Pk_sigma_ratio = D(InitialRedshift)/D(z_file)` and zeldovich multiplies
the table by its square. TNG's raw table does not satisfy that: its shape is right but its amplitude is
not physical (sigma_8 = 0.6766). TNG itself (N-GenIC) used only the shape: it renormalized the table to
sigma_8 = 0.8159 at z = 0 and divided by its growth factor D(0)/D(127) = 100.387.

So, before Abacus reads anything, we rescaled the table by hand to a true z = 1 spectrum
(`make_z1_table.py`):

    P_z1(k) = P_z0(k) * (0.8159 / 0.6766)^2 * (D(1)/D(0))^2,   D(1)/D(0) = 0.6087749

with D from `abacus.cosmo` for this cosmology (the same growth function abacus.py uses for
ZD_Pk_sigma_ratio), giving sigma_8(z=1) = 0.4967. Abacus then scales it from z = 1 to z_init:

    sigma_8(z_init) = 0.4967 * D(z_init)/D(1) = 0.8159 * D(z_init)/D(0)

e.g. 0.008128 at z = 127 (= Ralf's ZD_Pk_sigma; D(127)/D(0) = 0.0099615 vs TNG's 1/100.387 = 0.0099614)
and 0.010403 at z = 99 (checked: zeldovich logged Final sigma(8) = 0.0104033 in run A).

This two-step rescaling is exact only because growth is scale independent (no massive neutrinos), so
the spectrum's shape is the same at every redshift. Equivalent alternatives: `sigma_8 = 0.8159` with the
z = 0 table, or `ZD_Pk_sigma = sigma_8(z_init)` directly (what Ralf did), always with `ZD_Pk_norm = 8`.
Never use `ZD_Pk_file_redshift` with the raw TNG table: that would give sigma_8 = 0.6766.
