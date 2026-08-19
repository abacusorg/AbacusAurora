import argparse
import glob
import os
import shutil
import subprocess
import sys

import H0_search
import table_to_ini


def _run(cmd):
    print(cmd, flush=True)
    r = subprocess.run(cmd, shell=True)
    if r.returncode != 0:
        raise SystemExit(f"command failed ({r.returncode}): {cmd}")

# Elbers CLASS @ 6cf8e3 (must match installed classy)
class_dir = os.path.expanduser("~/class_public/class ")

# Default glass for A_s / optional per-cosm theta (override via --glass)
from_emulator = 1
GLASS_DAT = "desi_secondaries.dat"

# Staging table with only cosm200/201/210 (avoids reprocessing historical TBD rows)
DEFAULT_TABLE = "../Cosmologies/desi_secondaries_grid"


def _finished_rows(readme_txt):
    """
    Rows in README.txt that already have measured sigma8 (keep across re-runs).
    before H0_search, snapshot README.txt rows that already have measured sigma8;
    after H0_search, write them back so re-runs dont wipe finished cosms

    """
    keep = {}
    if not os.path.isfile(readme_txt):
        return keep
    for line in open(readme_txt):
        if not line.startswith("| abacus_cosm"):
            continue
        parts = [p.strip() for p in line.strip().strip("|").split("|")]
        # header has sigma8_m, sigma8_cb as last two; finished rows fill them
        if len(parts) >= 15 and parts[-2] and parts[-1]:
            try:
                float(parts[-2])
                float(parts[-1])
            except ValueError:
                continue
            keep[parts[0]] = line if line.endswith("\n") else line + "\n"
    return keep


def _restore_finished(readme_txt, keep):
    if not keep or not os.path.isfile(readme_txt):
        return
    out = []
    seen = set()
    for line in open(readme_txt):
        if line.startswith("| abacus_cosm"):
            root = line.split("|")[1].strip()
            if root in keep:
                out.append(keep[root])
                seen.add(root)
                continue
        out.append(line if line.endswith("\n") else line + "\n")
    with open(readme_txt, "w") as f:
        f.writelines(out)


def main(
    table=DEFAULT_TABLE,
    force=False,
    glass=None,
    per_cosm_theta=False,
):
    glass_dat = glass or GLASS_DAT
    readme_txt = "../Cosmologies/README.txt"
    keep = _finished_rows(readme_txt)

    # Solve TBD h → writes Cosmologies/README.txt
    H0_search.main(
        new=["table", table],
        per_cosm_theta=per_cosm_theta,
        glass=glass_dat if per_cosm_theta else None,
    )
    # Preserve already-finished rows (e.g. cosm200 when only 201/210 are new)
    _restore_finished(readme_txt, keep)

    # Transform README.txt into Cosmologies/<root>.ini
    table_to_ini.main()

    os.chdir("../Cosmologies/")
    inputs = sorted(glob.glob("*.ini"))
    print("All inputs: ", inputs)

    for ini in inputs:
        root = ini[:-4]
        if os.path.isdir(root):
            if force:
                print("FORCE: removing existing directory " + root)
                shutil.rmtree(root)
            else:
                # Leave existing Aurora products untouched (e.g. cosm000, cosm176)
                print("Skipped and deleted " + ini + " (dir exists; pass --force to redo)")
                os.unlink(ini)
                continue
        os.mkdir(root)
        os.chdir(root)
        shutil.copy("../" + ini, ini)

        if "With A_s calibration" in open(ini).read():
            _run(class_dir + ini + " ../abacus_base_fast.pre > " + root + ".out")
            os.chdir("../../util/")
            os.environ["ABACUS_GLASS_DAT"] = glass_dat
            _run(
                "python calibrate_A_s.py "
                + root
                + " "
                + str(from_emulator)
            )
            table_to_ini.main()
            os.chdir("../Cosmologies/" + root)
            shutil.copy("../" + ini, ini)

        _run(class_dir + ini + " ../abacus_base.pre > " + root + ".out")
        os.chdir("../")
        _run("python ../util/write_s8.py " + root)

    for f in inputs:
        if os.path.isfile(f):
            os.unlink(f)
    print("Deleted all input files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Run H0_search + CLASS for cosmologies in a | table"
    )
    parser.add_argument(
        "--table",
        default=DEFAULT_TABLE,
        help="input | table (copied to README.txt by H0_search)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="delete and redo cosm dirs that already exist (dangerous)",
    )
    parser.add_argument(
        "--glass",
        default=None,
        help="glass .dat for A_s (and theta factors if --per-cosm-theta); "
        "default: desi_secondaries.dat",
    )
    parser.add_argument(
        "--per-cosm-theta",
        action="store_true",
        help="H0_search: theta_def = theta0 * factor from glass last column",
    )
    args = parser.parse_args()
    # run from util/
    os.chdir(os.path.dirname(os.path.abspath(__file__)) or ".")
    main(
        table=args.table,
        force=args.force,
        glass=args.glass,
        per_cosm_theta=args.per_cosm_theta,
    )
