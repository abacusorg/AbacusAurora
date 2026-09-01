#!/usr/bin/env python3
"""Offline replay of nodehealth.py against real Aurora failure logs.

Run from anywhere:  python3 job/test/nodehealth/test_nodehealth.py
No pytest, no network, no Aurora.  Exits nonzero on the first failure.

The fixtures in this directory are verbatim excerpts from seven production
failures (jobs 8766714, 8766809, 8778470, 8778478).  They are the reason the
grading rules look the way they do, so they are the regression suite.
"""

import os
import shutil
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
tool = os.path.join(here, "..", "..", "nodehealth.py")

failures = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}  {detail}")
        failures.append(name)


def hostfile(path, hosts, pad_to=0, prefix="x9999c0s0b0n"):
    """A synthetic hostfile containing `hosts` plus filler up to pad_to lines."""
    lines = list(hosts)
    i = 0
    while len(lines) < pad_to:
        cand = f"{prefix}{i}"
        if cand not in lines:
            lines.append(cand)
        i += 1
    with open(path, "w") as f:
        f.write("".join(h + "\n" for h in lines))
    return lines


def pool(path, n, prefix="x8888c0s0b0n"):
    with open(path, "w") as f:
        f.write("".join(f"{prefix}{i}\n" for i in range(n)))


def run(*args, **kw):
    return subprocess.run([sys.executable, tool, *args],
                          capture_output=True, text=True, **kw)


def replace(work, log, hosts, sim=0, attempt=2, spares=4, history=None,
            statedir=None, order=None):
    """Set up a scratch job dir and run one `replace`.  Returns (rc, stderr, out)."""
    hf = os.path.join(work, "nodefile_part_000")
    hostfile(hf, hosts, pad_to=max(16, len(hosts)))
    if order is not None:
        with open(hf, "w") as f:
            f.write("".join(h + "\n" for h in order))
    pl = os.path.join(work, "hostfile_extra")
    pool(pl, spares)
    sd = statedir or os.path.join(work, "nodehealth")
    out = hf + f".a{attempt}"
    r = run("replace", "--log-slice", log, "--hostfile", hf, "--pool", pl,
            "--statedir", sd, "--sim", str(sim), "--attempt", str(attempt),
            "--out", out, *(["--history", history] if history else []))
    return r.returncode, r.stderr, out


# --- 1. the seven production logs -------------------------------------------

print("1. replay of the seven production failures")

shepherd_cases = [
    ("8766714_sim_2", "x4117c0s6b0n0", "x4115c5s4b0n0"),
    ("8766714_sim_6", "x4400c2s7b0n0", "x4400c4s5b0n0"),
    ("8766714_sim_14", "x4610c4s3b0n0", "x4610c7s2b0n0"),
]
for stem, blamed, collateral in shepherd_cases:
    with tempfile.TemporaryDirectory() as work:
        rc, err, out = replace(work, os.path.join(here, stem + ".log"),
                               [blamed, collateral])
        new = open(out).read().split() if os.path.exists(out) else []
        check(f"{stem}: replaced", rc == 0, f"rc={rc}\n{err}")
        check(f"{stem}: {blamed} gone", blamed not in new)
        check(f"{stem}: {collateral} kept (teardown collateral)", collateral in new)
        check(f"{stem}: node count preserved", len(new) == 16, f"got {len(new)}")

with tempfile.TemporaryDirectory() as work:
    rc, err, out = replace(work, os.path.join(here, "8778470_sim_5.log"),
                           ["x4709c2s3b0n0"])
    new = open(out).read().split() if os.path.exists(out) else []
    check("8778470_sim_5: ping timeout replaces the silent node", rc == 0, err)
    check("8778470_sim_5: x4709c2s3b0n0 gone", "x4709c2s3b0n0" not in new)

sig11_cases = [
    ("8766809_sim_9", "x4511c1s3b0n0"),
    ("8766809_sim_21", "x4716c7s5b0n0"),
    ("8778478_sim_1", "x4300c5s6b0n0"),
]
for stem, host in sig11_cases:
    with tempfile.TemporaryDirectory() as work:
        rc, err, out = replace(work, os.path.join(here, stem + ".log"), [host])
        check(f"{stem}: sig 11 takes a strike, no replacement", rc == 1,
              f"rc={rc}\n{err}")
        check(f"{stem}: no new hostfile written", not os.path.exists(out))

# --- 2. the systematic-software suppressor ----------------------------------

print("2. same (phase, sig) on a second host stops blaming nodes")
with tempfile.TemporaryDirectory() as work:
    sd = os.path.join(work, "nodehealth")
    hist = os.path.join(work, "nodehealth.tsv")
    for i, (stem, host) in enumerate(sig11_cases):
        w = os.path.join(work, f"sim{i}")
        os.makedirs(w)
        rc, err, _ = replace(w, os.path.join(here, stem + ".log"), [host],
                             sim=i, statedir=sd, history=hist)
        if i == 0:
            check("first sig-11 occurrence: strike", rc == 1, err)
            check("  ...and it reached the history file", os.path.exists(hist))
        else:
            check(f"occurrence {i + 1}: recognised as systematic",
                  "systematic" in err, err)
    hosts_in_history = [ln.split("\t")[0] for ln in open(hist)
                        if not ln.startswith("#") and ln.strip()]
    check("only the first host was ever struck", hosts_in_history == ["x4511c1s3b0n0"],
          str(hosts_in_history))

print("3. a repeat offender is replaced on its second medium/strike offence")
with tempfile.TemporaryDirectory() as work:
    hist = os.path.join(work, "nodehealth.tsv")
    host = "x4511c1s3b0n0"
    w1 = os.path.join(work, "a")
    os.makedirs(w1)
    rc1, _, _ = replace(w1, os.path.join(here, "8766809_sim_9.log"), [host],
                        history=hist, statedir=os.path.join(work, "sd_a"))
    w2 = os.path.join(work, "b")
    os.makedirs(w2)
    rc2, err2, out2 = replace(w2, os.path.join(here, "8766809_sim_9.log"), [host],
                              history=hist, statedir=os.path.join(work, "sd_b"))
    check("first offence: strike", rc1 == 1)
    check("second offence: escalated to a replacement", rc2 == 0, err2)
    check("  ...and the host is gone from the new hostfile",
          host not in open(out2).read().split() if rc2 == 0 else False)

print("4. absolve clears this job's strikes after a healthy run")
with tempfile.TemporaryDirectory() as work:
    hist = os.path.join(work, "nodehealth.tsv")
    sd = os.path.join(work, "nodehealth")
    host = "x4511c1s3b0n0"
    w = os.path.join(work, "a")
    os.makedirs(w)
    replace(w, os.path.join(here, "8766809_sim_9.log"), [host],
            history=hist, statedir=sd)
    check("strike recorded", host in open(hist).read())
    hf = os.path.join(w, "nodefile_part_000")
    r = run("absolve", "--hostfile", hf, "--statedir", sd, "--history", hist)
    check("absolve succeeded", r.returncode == 0, r.stderr)
    check("strike cleared", host not in open(hist).read(), open(hist).read())

# --- 5. no spares left -------------------------------------------------------

print("5. an empty spare pool aborts the sim rather than relaunching")
with tempfile.TemporaryDirectory() as work:
    rc, err, out = replace(work, os.path.join(here, "8766714_sim_2.log"),
                           ["x4117c0s6b0n0", "x4115c5s4b0n0"], spares=0)
    check("exit 2 when the pool is empty", rc == 2, f"rc={rc}\n{err}")
    check("no hostfile written", not os.path.exists(out))

with tempfile.TemporaryDirectory() as work:
    hist = os.path.join(work, "nodehealth.tsv")
    rc, err, out = replace(work, os.path.join(here, "8766714_sim_2.log"),
                           ["x4117c0s6b0n0", "x4115c5s4b0n0"], spares=0,
                           history=hist)
    row = [ln for ln in open(hist) if ln.startswith("x4117c0s6b0n0")]
    check("the blamed host is still recorded as confirmed-bad, so the next "
          "job quarantines it", len(row) == 1 and row[0].split("\t")[2] == "1",
          str(row))

# --- 6. concurrent claims ----------------------------------------------------

print("6. sixteen concurrent claims against an eight-node pool")
with tempfile.TemporaryDirectory() as work:
    pl = os.path.join(work, "hostfile_extra")
    pool(pl, 8)
    # Separate state dirs on purpose: this exercises the pool lock, not the
    # diagnosis.  Sharing one would (correctly) trip the correlated-event
    # suppressor -- that path is test 9.
    procs = []
    for i in range(16):
        w = os.path.join(work, f"sim{i}")
        os.makedirs(w)
        sd = os.path.join(w, "nodehealth")
        hf = os.path.join(w, "nodefile_part_000")
        hostfile(hf, [f"x40{i:02d}c0s0b0n0", "x4115c5s4b0n0"], pad_to=8)
        # Each sim blames its own distinct host, so all sixteen want a spare.
        log = os.path.join(w, "slice.log")
        with open(log, "w") as f:
            f.write(f"x40{i:02d}c0s0b0n0.hsn.cm.aurora.alcf.anl.gov: "
                    "shepherd died from signal 9\n")
        procs.append((i, subprocess.Popen(
            [sys.executable, tool, "replace", "--log-slice", log,
             "--hostfile", hf, "--pool", pl, "--statedir", sd,
             "--sim", str(i), "--out", hf + ".a2"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)))
    rcs = []
    for i, p in procs:
        p.wait()
        rcs.append(p.returncode)
    check("exactly 8 claimed a spare", rcs.count(0) == 8, str(rcs))
    check("exactly 8 gave up", rcs.count(2) == 8, str(rcs))
    claimed = []
    for i in range(16):
        c = os.path.join(work, f"sim{i}", "nodehealth", "claimed.tsv")
        if os.path.exists(c):
            claimed += [ln.split("\t")[2].strip() for ln in open(c)]
    check("no spare handed out twice", len(claimed) == len(set(claimed)),
          str(sorted(claimed)))
    check("pool drained cleanly", open(pl).read().strip() == "",
          repr(open(pl).read()))

# --- 7. order-nodes quarantine ----------------------------------------------

print("7. order-nodes holds back known-bad nodes")
with tempfile.TemporaryDirectory() as work:
    hist = os.path.join(work, "nodehealth.tsv")
    with open(hist, "w") as f:
        f.write("# host\tstrikes\tconfirmed\tfirst_seen\tlast_seen\treasons\n")
        f.write("x4117c0s6b0n0\t3\t1\t2026-08-01T00:00:00+00:00\t"
                "2026-08-28T00:00:00+00:00\tshepherd-killed\n")
        f.write("x4400c2s7b0n0\t1\t0\t2026-08-01T00:00:00+00:00\t"
                "2026-08-28T00:00:00+00:00\tapp-signal\n")
    nodes = os.path.join(work, "nodes.sorted")
    hostfile(nodes, ["x4117c0s6b0n0", "x4400c2s7b0n0"], pad_to=10)
    good, quar = os.path.join(work, "good"), os.path.join(work, "quar")
    r = run("order-nodes", "--nodes", nodes, "--history", hist,
            "--good", good, "--quarantine", quar, "--required", "8")
    g, q = open(good).read().split(), open(quar).read().split()
    check("order-nodes succeeded", r.returncode == 0, r.stderr)
    check("confirmed-bad node quarantined", q == ["x4117c0s6b0n0"], str(q))
    check("single-strike node still usable", "x4400c2s7b0n0" in g)
    check("nothing lost", len(g) + len(q) == 10)

    # ...unless holding it back would leave too few nodes to place the sims.
    r = run("order-nodes", "--nodes", nodes, "--history", hist,
            "--good", good, "--quarantine", quar, "--required", "10")
    g, q = open(good).read().split(), open(quar).read().split()
    check("quarantine yields when the sims would not fit", q == [] and len(g) == 10,
          f"good={len(g)} quar={q}")
    check("original order preserved", g == open(nodes).read().split(), str(g))

# --- 8. things that must never be blamed ------------------------------------

print("8. NODEWARN, FSSTALL and assert failures never blacklist")
with tempfile.TemporaryDirectory() as work:
    log = os.path.join(work, "slice.log")
    with open(log, "w") as f:
        f.write(
            'NODEWARN t=2026-08-28T12:00:00 elapsed=120 host=x4504c5s1b0n0 rank=20'
            ' op="derivative recv-Waitall" peerhost=x4504c5s1b0n0 stalled=120s\n'
            'Failed Assertion [host=x4504c5s1b0n0 rank=20]: something\n')
    rc, err, out = replace(work, log, ["x4504c5s1b0n0"])
    check("NODEWARN alone blames nobody", rc == 1, f"rc={rc}\n{err}")

with tempfile.TemporaryDirectory() as work:
    log = os.path.join(work, "slice.log")
    with open(log, "w") as f:
        f.write(
            'NODEFAIL t=2026-08-28T12:00:00 elapsed=500 host=x4504c5s2b0n0 rank=21'
            ' op="derivative recv-Waitall" peerhost=x4504c5s1b0n0 stalled=500s\n'
            'NODEFAIL t=2026-08-28T12:00:00 elapsed=500 host=x4504c5s3b0n0 rank=23'
            ' op="derivative recv-Waitall" peerhost=x4504c5s1b0n0 stalled=500s\n'
            'FSSTALL t=2026-08-28T12:00:00 elapsed=500 host=x4504c5s1b0n0 rank=20'
            ' file="/lus/flare/Derivatives/x" waited=500s\n')
    rc, err, out = replace(work, log,
                           ["x4504c5s1b0n0", "x4504c5s2b0n0", "x4504c5s3b0n0"])
    check("FSSTALL exonerates the accused peer", rc == 1, f"rc={rc}\n{err}")
    check("  ...and says so", "exonerated" in err, err)

with tempfile.TemporaryDirectory() as work:
    log = os.path.join(work, "slice.log")
    with open(log, "w") as f:
        f.write(
            'NODEFAIL t=2026-08-28T12:00:00 elapsed=500 host=x4504c5s2b0n0 rank=21'
            ' op="derivative recv-Waitall" peerhost=x4504c5s1b0n0 stalled=500s\n'
            'NODEFAIL t=2026-08-28T12:00:00 elapsed=500 host=x4504c5s3b0n0 rank=23'
            ' op="derivative recv-Waitall" peerhost=x4504c5s1b0n0 stalled=500s\n')
    rc, err, out = replace(work, log,
                           ["x4504c5s1b0n0", "x4504c5s2b0n0", "x4504c5s3b0n0"])
    new = open(out).read().split() if os.path.exists(out) else []
    check("two accusers of one peer replace that peer", rc == 0, f"rc={rc}\n{err}")
    check("  ...the peer, not the accusers", "x4504c5s1b0n0" not in new
          and "x4504c5s2b0n0" in new and "x4504c5s3b0n0" in new, str(new))

# --- 9. correlated job-wide event -------------------------------------------

print("9. many sims failing at once is not many bad nodes")
with tempfile.TemporaryDirectory() as work:
    sd = os.path.join(work, "nodehealth")
    rcs = []
    for i, stem in enumerate([s for s, _, _ in shepherd_cases]):
        w = os.path.join(work, f"sim{i}")
        os.makedirs(w)
        blamed, collateral = [c for c in shepherd_cases if c[0] == stem][0][1:]
        rc, err, _ = replace(w, os.path.join(here, stem + ".log"),
                             [blamed, collateral], sim=i, statedir=sd)
        rcs.append(rc)
    check("the third simultaneous failure is downgraded",
          rcs[:2] == [0, 0] and rcs[2] == 1, str(rcs))

# --- 10. hostfile arithmetic -------------------------------------------------

print("10. rank 0 stays put unless it is the node being replaced")
with tempfile.TemporaryDirectory() as work:
    order = ["x4115c5s4b0n0"] + [f"x9999c0s0b0n{i}" for i in range(14)] + \
            ["x4117c0s6b0n0"]
    rc, err, out = replace(work, os.path.join(here, "8766714_sim_2.log"),
                           [], order=order)
    new = open(out).read().split()
    check("line 1 unchanged", new[0] == "x4115c5s4b0n0", str(new[:2]))
    check("the blamed node is substituted in place, last line",
          new[-1].startswith("x8888"), str(new[-3:]))
    check("length unchanged", len(new) == len(order))

print()
if failures:
    print(f"{len(failures)} check(s) FAILED: {', '.join(failures)}")
    sys.exit(1)
print("all checks passed")
