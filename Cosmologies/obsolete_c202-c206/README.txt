Obsolete FLAMINGO cosmologies abacus_cosm202-206: the versions registered on main from 2026-09-29 (e6cb0a9) until they were
replaced by the FLAMINGO-matched inputs in Cosmologies/abacus_cosm202-206 (branch flamingo-n2500, merged 2026-11). Byte-identical
copies of main's old CLASS.ini, CLASS_power, CLASS_transfer and cosm.def.
202 Planck, 203 PlanckNu0p12Var, 204 PlanckNu0p24Fix, 205 PlanckNu0p48Fix, 206 PlanckNu0p24Var.

They were made with the standard AbacusAurora pipeline (~/class_public + abacus_base.pre: 2011 HyRec, pk_ref precision, YHe = BBN,
reio_camb), N_ur = 2.0328, all neutrino mass in ONE species, and h rounded to 3 decimals. That does not match FLAMINGO's production
inputs (three degenerate neutrinos with N_ur = 0.00441 for the PlanckNu boxes, N_ur = 2.0308, full-precision h and Omegas, CLASS
v2.9.4 with RECFAST and monofonIC precision): up to 3.2% off in P_cb (PlanckNu0p48Fix) and a ~0.5% stronger BAO amplitude for all.
See Cosmologies/FLAMINGO_cosm/FLAMINGO_MATCHING.md. Kept only so that runs made with them stay reproducible; do not use for new runs.
