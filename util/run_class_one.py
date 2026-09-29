"""
Run one stage of the run_class.py pipeline for a single massive-nu cosm, so several
cosms can run in parallel on separate PBS nodes. h must already be solved in
README.txt (no H0_search here), and Cosmologies/<root>/<root>.ini must already exist.

  calib: CLASS (abacus_base.pre) -> calibrate_A_s.py -> table_to_ini -> refresh <root>.ini
  final: CLASS (abacus_base.pre) -> write_s8.py

Every README.txt read-modify-write happens under a mkdir lock (atomic on any
filesystem). --wait-log makes calib wait for another run_class.py (e.g. the login
node) to exit first, because that one writes README.txt without the lock.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
from contextlib import contextmanager

import table_to_ini

UTIL = os.path.dirname(os.path.abspath(__file__))
COSMO = os.path.join(UTIL, "..", "Cosmologies")
CLASS = os.path.expanduser("~/class_public/class")
LOCK = os.path.join(COSMO, "README.txt.lock")


def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, flush=True)


def run(cmd, cwd):
    log(f"[{os.path.basename(cwd)}] {cmd}")
    r = subprocess.run(cmd, shell=True, cwd=cwd)
    if r.returncode != 0:
        raise SystemExit(f"command failed ({r.returncode}): {cmd}")


@contextmanager
def readme_lock(timeout=1800):
    t0 = time.time()
    while True:
        try:
            os.mkdir(LOCK)
            break
        except FileExistsError:
            if time.time() - t0 > timeout:
                raise SystemExit(f"timed out waiting for {LOCK}")
            time.sleep(2)
    try:
        yield
    finally:
        os.rmdir(LOCK)


def wait_for_log(path, marker="Deleted all input files", timeout=3000):
    t0 = time.time()
    while marker not in open(path).read():
        if time.time() - t0 > timeout:
            raise SystemExit(f"timed out waiting for '{marker}' in {path}")
        time.sleep(15)
    log(f"found '{marker}' in {path}")


def run_class(root):
    cdir = os.path.join(COSMO, root)
    ini = root + ".ini"
    if not os.path.isfile(os.path.join(cdir, ini)):
        raise SystemExit(f"missing {cdir}/{ini}")
    run(f"{CLASS} {ini} ../abacus_base.pre > {root}.out", cdir)


def calib(root, glass, wait_log):
    cdir = os.path.join(COSMO, root)
    if "With A_s calibration" not in open(os.path.join(cdir, root + ".ini")).read():
        raise SystemExit(f"{root}.ini is already calibrated; run the final stage")
    run_class(root)
    if wait_log:
        wait_for_log(wait_log)
    os.environ["ABACUS_GLASS_DAT"] = glass
    with readme_lock():
        run(f"{sys.executable} calibrate_A_s.py {root} 1", UTIL)
        os.chdir(UTIL)
        table_to_ini.main()
        shutil.copy(os.path.join(COSMO, root + ".ini"), os.path.join(cdir, root + ".ini"))
        # table_to_ini writes every row; drop the top-level copies again
        for row_ini in (f for f in os.listdir(COSMO) if f.startswith("abacus_cosm") and f.endswith(".ini")):
            os.unlink(os.path.join(COSMO, row_ini))
    text = open(os.path.join(cdir, root + ".ini")).read()
    if "With A_s calibration" in text:
        raise SystemExit(f"{root}.ini still uncalibrated after calibrate_A_s")
    log(f"[{root}] calibrated: " + [l for l in text.splitlines() if l.startswith("A_s")][0])


def final(root):
    run_class(root)
    with readme_lock():
        run(f"{sys.executable} write_s8.py {root}", UTIL)
    log(f"[{root}] done")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("stage", choices=["calib", "final"])
    p.add_argument("root", help="e.g. abacus_cosm212")
    p.add_argument("--glass", default="neutrino_glass.dat")
    p.add_argument("--wait-log", default=None, help="run_class.py log to wait on before touching README.txt")
    a = p.parse_args()
    os.chdir(UTIL)
    if a.stage == "calib":
        calib(a.root, a.glass, a.wait_log)
    else:
        final(a.root)
