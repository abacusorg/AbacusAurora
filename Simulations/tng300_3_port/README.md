# TNG300-3 640^3 port

Abacus runs of TNG300-3's initial density field, to compare against TNG300-3-Dark. All runs use Ralf Konietzka's
640^3 white noise (TNG300-3's N-GenIC noise, written out in Fourier space and converted to the Abacus "xfast"
format; see Ralf's notes), so every run is mode-by-mode the same realization as TNG300-3.

Common to all (`tng300_3_wn640.def`): L = 205 Mpc/h, NP = 640^3, CPD = 153, NumZRanks = 1, softening
ell/40 = 8 kpc/h (= TNG300-3's), full particle slices at the exact TNG snapshot redshifts 20.0465 (snap 0),
4.9959 (17), 3.0081 (25) and 0 (99), no light cones. TNG cosmology: Omega_m = 0.3089, h = 0.6774,
n_s = 0.9667, sigma_8 = 0.8159, no massive neutrinos (`Cosmologies/tng_planck2015*`).

## The four IC choices

| Choice | Options |
|---|---|
| P(k) | TNG's CAMB table, shape only, normalized to sigma_8 = 0.8159 (`tng_planck2015`, as N-GenIC did); or CLASS with TNG's published cosmology, massless nu (`tng_planck2015_class`) |
| z_init | 99 (Abacus standard) or 127 (TNG) |
| PLT | on (Abacus standard: particle-lattice eigenmode corrections, rescaled to z = 12) or off (TNG) |
| LPT | 2LPT (Abacus standard, 2 extra force steps at z_init) or Zel'dovich only (TNG) |

TNG's own recipe is CAMB table, z = 127, no PLT, Zel'dovich.

## Runs

`#` numbers follow the 16-combination list (P(k) x z_init x PLT x LPT).

| # | Run (SimName) | P(k) | z_init | PLT | LPT | Purpose |
|---|---|---|---|---|---|---|
| 1 | `TNG300-3_wn640_z99PLT` (run A) | CAMB | 99 | on | 2LPT | Abacus standard recipe |
| 8' | `TNG300-3_ralfIC_z127` (run B) | CAMB | 127 | off | ZA | TNG's recipe, using Ralf's IC files (made with zeldovich_mpi on FASRC) |
| 3 | `TNG300-3_wn640_camb_z99_noPLT_2LPT` | CAMB | 99 | off | 2LPT | vs #1: effect of PLT at z = 99 |
| 5 | `TNG300-3_wn640_camb_z127_PLT_2LPT` | CAMB | 127 | on | 2LPT | vs #1: effect of z_init = 127 vs 99 (Abacus recipe otherwise) |
| 7 | `TNG300-3_wn640_camb_z127_noPLT_2LPT` | CAMB | 127 | off | 2LPT | vs #8: effect of 2LPT at z = 127; vs #5: effect of PLT at z = 127; vs #3: effect of z_init without PLT |
| 8 | `TNG300-3_wn640_camb_z127_noPLT_ZA` | CAMB | 127 | off | ZA | TNG's recipe with ICs made here. ICs vs Ralf's files: reproduction check (expect float-level agreement); outputs vs run B: should be identical |
| 9 | `TNG300-3_wn640_class_z99_PLT_2LPT` | CLASS | 99 | on | 2LPT | vs #1: effect of the P(k) source (CLASS vs TNG's CAMB table) with the Abacus recipe |
| 16 | `TNG300-3_wn640_class_z127_noPLT_ZA` | CLASS | 127 | off | ZA | vs #8: effect of the P(k) source with TNG's recipe; vs TNG: how well the documented cosmology alone reproduces TNG |

Other files: `TNG300-3_wn640_z99PLT_toz20.par2` (gate run of #1, stops at z = 20.05);
`TNG300-3_wn640_nu_*.par2` (Ralf's 0.06 eV reconstruction of the CAMB table; not run, since TNG's
simulations never used a massive neutrino).

The test runs (#3-#16) share `tng300_3_ictest.def`: noise settings, and their generated ICs are kept
(`ICCleanupMode = "Never"`) in `/flare/Abacus/helenshao/ICs/tng300_3_wn640/ic_<SimName>/` (ic_0000..ic_0152,
RVZel_2D, 8.4 GB) for IC-level comparisons. Outputs go to `/flare/Abacus/helenshao/<SimName>/`.

## Amplitude

All CAMB-table runs set sigma_8(z_init) = 0.8159 * D(z_init)/D(0) with D from abacus.cosmo: 0.010403 at
z = 99, 0.0081276 at z = 127 (= Ralf's ZD_Pk_sigma = 0.008128). See `Cosmologies/tng_planck2015/README.md`
for why ZD_Pk_file_redshift = 1 is valid with the hand-rescaled z = 1 table. Check the zeldovich log line
`Final sigma(8.000000)` against these values.

## Results so far

Runs A and B vs TNG300-3-Dark (analysis in `~/InitialConditions/tng300_3_port_analysis/`): the white noise is
TNG300-3's realization with no axis permutation, flip or shift (r(k) = 1.0000 at k < 1 h/Mpc at z = 20); run B
matches TNG's P(k) to <= 0.5% to k = 5 h/Mpc at all redshifts, run A has +1-10% small-scale power at high z
from 2LPT + PLT, decaying to ~1% at z = 0.

#3 and #7 (2LPT without PLT) crash on the main code (LPTVelScale = max|v - displ| is pure roundoff when v = displ,
so the uint16 aux packing overflows in the first 2LPT kick). They were run on branch `lpt-velscale-floor`
(ce053e2, floor LPTVelScale at 1e-7; PLT runs unchanged), job 9108022; all other test runs used 744d747.

Splitting A's excess vs TNG: PLT dominates at high z (A vs #3: +13% at k = 5, +2.3% at k = 2 at z = 20; ~0 at
z = 0); 2LPT vs ZA (#7 vs #8) is +1% at k = 5 at z = 20, grows to +3-4% at k = 2-5 at z = 3-5, and leaves the
~+1% at k = 0.5-5 at z = 0 that A shows vs TNG (TNG's own ZA transients). z_init matters little in either recipe.

#2 (`TNG300-3_wn640_camb_z99_PLT_ZA`) and #4 (`TNG300-3_wn640_camb_z99_noPLT_ZA`), par files in this directory,
code 744d747, jobs 9108899 / 9109115. Best z_init = 99 recipe for matching TNG: no PLT, ZA (#4): within 0.5% of TNG to
k ~ 5 at z <= 5 (-0.4% at k ~ 1 at z = 0, vs #8's -0.14%), +2.7% at k = 5 at z = 20. 2LPT adds a flat +1.0-1.3% at
k >= 0.5 at z = 0 with or without PLT (A vs #2 = #3 vs #4); PLT only matters at high z. Run A's ICs were regenerated
(stopped at z = 20; P(k) matches run A to 7e-6) into `ICs/tng300_3_wn640/ic_TNG300-3_wn640_camb_z99_PLT_2LPT/`.
