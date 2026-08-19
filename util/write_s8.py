import os
import sys

# names: root directory in the table, abacus power spectrum and abacus transfer function
INPUT = "CLASS_power"
TRANSFER = "CLASS_transfer"
INIFILE = "CLASS.ini"

sig8 = "sigma8="
for_m = "total matter"
for_cb = "baryons+cdm"

table = "README.txt"

root = sys.argv[1]
os.chdir("../Cosmologies/")
out = os.path.join(root, root + ".out")

s8_m = None
s8_cb = None
for line in open(out):
    if sig8 in line and for_m in line:
        s8_m = format(float(line.split(sig8)[-1].split()[0]), "8.6f")
    elif sig8 in line and for_cb in line:
        s8_cb = format(float(line.split(sig8)[-1].split()[0]), "9.6f")

if s8_m is None:
    raise SystemExit(
        f"write_s8: no 'sigma8=' / total matter in {out} "
        "(empty .out usually means CLASS was killed)"
    )
if s8_cb is None:
    s8_cb = format(float(s8_m), "9.6f")


def _patch_sigma8_line(line, s8_m, s8_cb):
    """Replace or fill the last two table columns (sigma8_m, sigma8_cb)."""
    newline = "\n" if line.endswith("\n") else ""
    raw = line.rstrip("\n")
    content = [p.strip() for p in raw.strip().strip("|").split("|")]
    while len(content) < 13:
        content.append("")
    if len(content) == 13:
        content.extend([s8_m.strip(), s8_cb.strip()])
    else:
        content[13] = s8_m.strip()
        if len(content) == 14:
            content.append(s8_cb.strip())
        else:
            content[14] = s8_cb.strip()
    return "| " + " | ".join(content) + " |" + newline


tmp = table + ".write_s8.tmp"
with open(table) as fin, open(tmp, "w") as fout:
    found = False
    for line in fin:
        if root in line and line.lstrip().startswith("|"):
            fout.write(_patch_sigma8_line(line, s8_m, s8_cb))
            found = True
        else:
            fout.write(line if line.endswith("\n") else line + "\n")
if not found:
    os.remove(tmp)
    raise SystemExit(f"write_s8: no README.txt row for {root}")
os.replace(tmp, table)


def _replace(src, dst):
    if os.path.exists(dst):
        os.remove(dst)
    os.rename(src, dst)


_replace(os.path.join(root, root + ".z2_tk.dat"), os.path.join(root, TRANSFER))
ini_src = os.path.join(root, root + ".ini")
if os.path.isfile(ini_src):
    _replace(ini_src, os.path.join(root, INIFILE))
pk_cb = os.path.join(root, root + ".z2_pk_cb.dat")
pk = os.path.join(root, root + ".z2_pk.dat")
if os.path.isfile(pk_cb):
    _replace(pk_cb, os.path.join(root, INPUT))
else:
    _replace(pk, os.path.join(root, INPUT))
