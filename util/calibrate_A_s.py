import numpy as np
import os
import re
import fileinput
import sys
from table_to_ini import list_param_names

ROOT = "root"
sig8 = "sigma8="
h = "h"
s8_cal = "sigma8_cb"
As = "A_s"
for_m = "total matter"
for_cb = "baryons+cdm"

# Working table (merged to README.md after the run)
table = "README.txt"

root = sys.argv[1]
from_emulator = int(sys.argv[2])

if from_emulator:
    glass = os.environ.get("ABACUS_GLASS_DAT", "desi_secondaries.dat")
    array = np.loadtxt(glass)
    cosmo = array[:, 0].astype(int)
    select = cosmo == int(root.split("abacus_cosm")[-1])
    assert np.sum(select) == 1, "Problem with your selection in " + glass
    # Membership in the glass file is enough (no hard cosmo > 115 cut)
    sigma8_cb = array[select, 1][0]
else:
    root_base = "abacus_cosm000"

os.chdir("../Cosmologies/")
output = os.path.join(root, root + ".out")


def get_A_s(As_i, s8_i, s8_f):
    return As_i * (s8_f / s8_i) ** 2


def construct_dict(root_name, fn, output_s8=False):
    param_names, names_row = list_param_names(fn, output_s8)
    par_dict = {}
    for line in open(fn):
        if root_name in line:
            line = re.sub(r"^\|\s*", "", line)
            line = re.sub(r"\s*\|\s*$", "", line)
            line = re.split(r"\s*\|\s*", line)
            for p, param in enumerate(param_names):
                if "TBD" in line[p] and param == h:
                    print("You should first fill in h")
                    exit()
                else:
                    par_dict[param] = line[p]
    return par_dict


for line in open(output):
    if sig8 in line and for_m in line:
        line = line.split(sig8)
        line = line[-1].split(" ")
        s8_m = float(line[0])
        s8_m = format(s8_m, "8.6f")
    elif sig8 in line and for_cb in line:
        line = line.split(sig8)
        line = line[-1].split(" ")
        s8_cb = float(line[0])
        s8_cb = format(s8_cb, "9.6f")

if not from_emulator:
    param_dict_base = construct_dict(root_base, table, output_s8=True)
param_dict = construct_dict(root, table)

for line in fileinput.FileInput(table, inplace=1):
    if root in line:
        A_s_ini = float(param_dict[As])
        if from_emulator:
            s8_base = sigma8_cb
        else:
            s8_base = float(param_dict_base[s8_cal])
        A_s = get_A_s(A_s_ini, float(s8_cb), s8_base)
        A_s = format(A_s, "11.4e")
        line = line.replace(param_dict[As], A_s)
    print(line, end="")
