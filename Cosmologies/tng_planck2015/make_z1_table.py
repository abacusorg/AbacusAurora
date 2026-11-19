#!/usr/bin/env python3
"""Make TNG_power_z1 from TNG's z=0 CAMB table (TNG_power_z0).

TNG's table has the right shape but its own sigma_8 is 0.677, not TNG's 0.8159. Following
the usual Abacus convention (a z=1 spectrum with ZD_Pk_file_redshift = 1), rescale it to
sigma_8 = 0.8159 at z=0 and then to z=1 with the linear growth factor:

    P_z1(k) = P_z0(k) * (0.8159 / sigma8_table)^2 * (D(1)/D(0))^2

D(1)/D(0) comes from abacus.cosmo, computed exactly as py/abacus/ic/zeldovich.py does for
ZD_Pk_sigma_ratio, so the table and Abacus's back-scaling to z_init use the same growth function.
Without massive neutrinos (Omega_Smooth = 0) growth is scale independent, so this gives the same
ICs as using the z=0 table with sigma_8 = 0.8159.

Usage (in this directory, with a Python that can import abacus.cosmo):
    python make_z1_table.py
"""

import numpy as np

import abacus.cosmo

SIGMA8 = 0.8159
Z_OUT = 1.0
COSMO = dict(Omega_M=0.3089, Omega_Smooth=0.0, Omega_K=0.0, Omega_DE=1 - 0.3089, H0=67.74, w0=-1.0, wa=0.0)


def sigma_R(k, P, R=8.0):
    """Top-hat sigma(R) of a tabulated P(k); k [h/Mpc], P [(Mpc/h)^3], R [Mpc/h]."""
    x = k * R
    W = 3 * (np.sin(x) - x * np.cos(x)) / x**3
    return np.sqrt(np.trapezoid(k**3 * P * W**2 / (2 * np.pi**2), np.log(k)))


def growth_ratio(z1, z2):
    """D(z1)/D(z2), as calc_growth_ratio() in py/abacus/ic/zeldovich.py."""
    return (abacus.cosmo.from_params(COSMO, z1).current.growth
            / abacus.cosmo.from_params(COSMO, z2).current.growth)


k, P0 = np.loadtxt('TNG_power_z0', unpack=True)
s8_table = sigma_R(k, P0)
D_ratio = growth_ratio(Z_OUT, 0.0)
P1 = P0 * (SIGMA8 / s8_table) ** 2 * D_ratio**2

header = (
    f"TNG P(k) at z = {Z_OUT:g}, made by make_z1_table.py from TNG_power_z0 (TNG's CAMB table)\n"
    f"table sigma_8 = {s8_table:.7f} rescaled to sigma_8(z=0) = {SIGMA8}; "
    f"D(z={Z_OUT:g})/D(0) = {D_ratio:.10f} from abacus.cosmo ({COSMO})\n"
    f"sigma_8(z={Z_OUT:g}) = {sigma_R(k, P1):.7f}\n"
    "k [h/Mpc]   P [(Mpc/h)^3]"
)
np.savetxt('TNG_power_z1', np.column_stack([k, P1]), fmt='%.8e', header=header)
print(header)
