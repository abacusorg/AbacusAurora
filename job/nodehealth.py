#!/usr/bin/env python3
"""nodehealth.py — decide whether a node killed a sim, and swap it for a spare.

Consumes the machine-greppable stderr markers that Abacus already emits (see
src/include/node_diag_logging.h in the code repo) plus the PALS launcher's own
death messages, all of which land in job/out/<jobid>/sim_<i>.out because
multisim.pbs merges stdout and stderr into it.

The design constraint that shapes everything here is that we must be able to
DECLINE to blame.  A software bug that segfaults a different rank every time
would otherwise retire a healthy node on each occurrence and burn the spare
pool.  So accusations are graded (high / medium / strike), two suppressors
look for the signature of a systematic bug or a job-wide event, and only a
surviving `high` causes an immediate replacement.

Stdlib only, deliberately: this must run on a laptop against a saved sim_N.out
so the rules can be checked offline before anyone trusts them in production.

Subcommands
    replace      diagnose, claim a spare, rewrite the hostfile   (used by onesim.sh)
    diagnose     report only, no state written                   (offline replay)
    order-nodes  split a nodefile into usable / quarantined      (used by multisim.pbs)
    absolve      undo this job's strikes after a healthy run     (used by onesim.sh)

`replace` exit codes are the whole contract with onesim.sh:
    0   --out was written; relaunch on it
    1   nobody blamed (or strike-only); relaunch unchanged
    2   a node is blamed but no spare is available; give up on this sim
    3   internal error; caller should fall back to relaunching unchanged
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
import re
import sys
import tempfile

# --- tunables ----------------------------------------------------------------

strike_decay_days = 14  # unconfirmed strikes older than this are forgotten
quarantine_strikes = 2  # strikes at which a node stops being assigned at all
correlated_window_s = 180  # sims failing within this of each other look job-wide
correlated_min_sims = 3  # ...and this many make it a job-wide event
systematic_min_hosts = 2  # same (phase,sig) on this many hosts ⇒ software bug

# Grades, most severe first.  `high` replaces immediately; `medium` replaces only
# if the host is already carrying a strike; `strike` only ever records one.
grades = ("high", "medium", "strike")


# --- small helpers -----------------------------------------------------------


def short_host(name):
    """x4117c0s6b0n0.hsn.cm.aurora.alcf.anl.gov: -> x4117c0s6b0n0"""
    return name.strip().strip(",:").split(".")[0]


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def parse_iso(s):
    try:
        return dt.datetime.fromisoformat(s)
    except ValueError:
        return dt.datetime.fromtimestamp(0, dt.timezone.utc)


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def read_hosts(path):
    """A hostfile as a list of short names, preserving order and duplicates."""
    return [short_host(ln) for ln in read_lines(path) if ln.strip()]


def write_atomic(path, text):
    d = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".nodehealth.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def locked(path):
    """Exclusive lock.  Every onesim.sh is a background child of one multisim.pbs
    on a single node, so a plain flock is enough — no distributed locking."""
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o664)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def say(msg):
    """Report on stderr with a prefix that can never look like a marker line:
    onesim.sh's own output lands in the same sim_N.out we slice, and we must not
    poison the next attempt's window."""
    print("# nodehealth: " + msg, file=sys.stderr)


# --- log parsing -------------------------------------------------------------

re_ping = re.compile(r"ping RPC timeout from (\S+) after (\d+)\s*s")
re_shepherd = re.compile(r"^\s*(\S+):\s*shepherd died from signal (\d+)")
re_rank_died = re.compile(r"^\s*(\S+):\s*rank (\d+) died from signal (\d+)")
re_fatal = re.compile(
    r"\*\*\* ABACUS FATAL: signal (\d+) on MPI rank (\d+) \(([^)]+)\)"
)
re_marker = re.compile(r"\b(NODEFAIL|NODEWARN|FSSTALL|MEMSTALL|RANK_IS_HEALTHY)\s+(t=|t_epoch=)")
re_kv = re.compile(r'(\w+)=("[^"]*"|\S+)')
# A status.log data row: two leading spaces then the step number.
re_step_row = re.compile(r"^\s{1,6}(\d+)\s+[-\d.]+\s+[-\d.]+\s")


def marker_fields(line):
    """Return (marker, {k: v}) for a NODEFAIL/FSSTALL/... line, else (None, {})."""
    m = re_marker.search(line)
    if not m:
        return None, {}
    fields = {}
    for k, v in re_kv.findall(line[m.start(2) :]):
        fields[k] = v.strip('"')
    return m.group(1), fields


class Evidence:
    """What one attempt's log slice says about who is to blame."""

    def __init__(self):
        self.accusations = []  # (host, grade, kind, detail)
        self.exonerated = set()  # FSSTALL/MEMSTALL: not the node's fault
        self.collateral = []  # hosts torn down by the launcher, never blamed
        self.healthy = set()  # RANK_IS_HEALTHY beacons
        self.peer_accusers = {}  # peerhost -> set of accusing hosts
        self.last_step = None
        self.reached_ready = False
        self.phase = None
        self.sig = None

    def accuse(self, host, grade, kind, detail=""):
        if host:
            self.accusations.append((short_host(host), grade, kind, detail))


def parse_slice(lines, hosts, ranks_per_node):
    """Extract evidence from one attempt's output.

    `hosts` is this sim's hostfile, used to resolve a bare rank to a host:
    aurora.def runs `-ppn 2 -np 2*NNODES`, so ranks are placed in blocks and
    rank r lives on hosts[r // ranks_per_node].
    """
    ev = Evidence()

    def host_of_rank(rank):
        idx = rank // ranks_per_node
        return hosts[idx] if 0 <= idx < len(hosts) else None

    for line in lines:
        m = re_step_row.match(line)
        if m:
            ev.last_step = int(m.group(1))
            continue

        if '# PHASE' in line and 'phase="ready"' in line:
            ev.reached_ready = True

        m = re_ping.search(line)
        if m:
            ev.accuse(m.group(1), "high", "pals-ping-timeout",
                      f"silent for {m.group(2)}s")
            continue

        m = re_shepherd.match(line)
        if m:
            host, sig = m.group(1), int(m.group(2))
            if sig == 9:
                # The shepherd is PALS's per-node agent; SIGKILL on it is the
                # initiating death, not the teardown.
                ev.accuse(host, "high", "shepherd-killed", "shepherd SIGKILL")
            else:
                ev.accuse(host, "medium", "shepherd-signal", f"shepherd sig {sig}")
            continue

        m = re_rank_died.match(line)
        if m:
            host, rank, sig = m.group(1), int(m.group(2)), int(m.group(3))
            if sig in (9, 15):
                # SIGTERM/SIGKILL of a rank is exactly what the launcher does to
                # everyone else once some other node has died.  Never blame it.
                ev.collateral.append((short_host(host), rank, sig))
            else:
                ev.accuse(host, "medium", "rank-signal", f"rank {rank} sig {sig}")
            continue

        m = re_fatal.search(line)
        if m:
            # Corroborates the NODEFAIL that crash_handler.h printed just above;
            # recorded for the report, not accused separately.
            ev.sig = ev.sig or int(m.group(1))
            continue

        marker, f = marker_fields(line)
        if marker is None:
            continue
        host = short_host(f.get("host", "")) if f.get("host") else None

        if marker in ("FSSTALL", "MEMSTALL"):
            if host:
                ev.exonerated.add(host)
            continue
        if marker == "RANK_IS_HEALTHY":
            if host:
                ev.healthy.add(host)
            continue
        if marker == "NODEWARN":
            # node_diag_logging.h:20-32 is explicit: NODEWARN must not blacklist.
            continue

        # NODEFAIL from here on.
        op = f.get("op", "")
        if "peerhost" in f:
            peer = short_host(f["peerhost"])
            ev.peer_accusers.setdefault(peer, set()).add(host or "?")
        elif op == "signal":
            ev.phase = f.get("phase") or ev.phase
            ev.sig = int(f["sig"]) if f.get("sig", "").isdigit() else ev.sig
            ev.accuse(host, "strike", "app-signal",
                      f'sig {f.get("sig", "?")} in phase {f.get("phase", "?")}')
        elif op.startswith("gpu ") or op.startswith("NumaAlloc "):
            ev.accuse(host, "high", "node-hardware", op)
        elif op.startswith("ring-probe"):
            for key in ("recv_from_rank", "send_to_rank"):
                if f.get(key, "").lstrip("-").isdigit():
                    peer = host_of_rank(int(f[key]))
                    if peer and peer != host:
                        ev.accuse(peer, "medium", "ring-probe", f"{op} {key}={f[key]}")
        elif host:
            ev.accuse(host, "medium", "nodefail", op or "unknown op")

    # Peer accusations: several ranks all naming the same stuck peer is strong.
    for peer, accusers in ev.peer_accusers.items():
        grade = "high" if len(accusers) >= 2 else "medium"
        ev.accuse(peer, grade, "peer-stall", f"{len(accusers)} accuser(s)")

    # Blame by exclusion, startup only: if beacons came in but one hostfile node
    # never beaconed, that node is the one that never woke up.
    if ev.healthy and not ev.reached_ready:
        silent = [h for h in hosts if h not in ev.healthy]
        if len(silent) == 1:
            ev.accuse(silent[0], "high", "no-healthy-beacon", "never beaconed")
        elif silent:
            for h in silent:
                ev.accuse(h, "strike", "no-healthy-beacon",
                          f"{len(silent)} nodes silent")

    return ev


def best_grade(accusations):
    """Collapse per-host accusations to one grade + reason each."""
    out = {}
    for host, grade, kind, detail in accusations:
        prev = out.get(host)
        if prev is None or grades.index(grade) < grades.index(prev[0]):
            out[host] = (grade, kind, detail)
        elif kind not in prev[1]:
            out[host] = (prev[0], prev[1] + "," + kind, prev[2])
    return out


# --- persistent history ------------------------------------------------------

history_columns = ("host", "strikes", "confirmed", "first_seen", "last_seen", "reasons")


def history_path(arg):
    return arg or os.environ.get("ABACUS_NODEHEALTH") or None


def load_history(path):
    """host -> dict.  Unconfirmed rows older than strike_decay_days are dropped."""
    rows = {}
    if not path or not os.path.exists(path):
        return rows
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=strike_decay_days)
    for ln in read_lines(path):
        if not ln.strip() or ln.startswith("#"):
            continue
        parts = ln.split("\t")
        if len(parts) < len(history_columns):
            parts += [""] * (len(history_columns) - len(parts))
        row = dict(zip(history_columns, parts))
        row["strikes"] = int(row["strikes"] or 0)
        row["confirmed"] = int(row["confirmed"] or 0)
        if not row["confirmed"] and parse_iso(row["last_seen"]) < cutoff:
            continue
        rows[row["host"]] = row
    return rows


def save_history(path, rows):
    body = ["# " + "\t".join(history_columns)]
    for host in sorted(rows):
        r = rows[host]
        body.append("\t".join(str(r[c]) for c in history_columns))
    write_atomic(path, "\n".join(body) + "\n")


def bump_history(path, host, kind, confirmed):
    """Record one strike (or a confirmed replacement) against `host`."""
    if not path:
        return
    with locked(path + ".lock"):
        rows = load_history(path)
        r = rows.get(host)
        if r is None:
            r = dict(host=host, strikes=0, confirmed=0,
                     first_seen=now_iso(), last_seen=now_iso(), reasons="")
            rows[host] = r
        r["strikes"] += 1
        r["confirmed"] = max(r["confirmed"], 1 if confirmed else 0)
        r["last_seen"] = now_iso()
        kinds = [k for k in r["reasons"].split(";") if k]
        if kind not in kinds:
            kinds.append(kind)
        r["reasons"] = ";".join(kinds[:6])
        save_history(path, rows)


def relieve_history(path, hosts, counts):
    """Undo strikes this job added, for hosts that have since run healthy."""
    if not path or not os.path.exists(path):
        return []
    relieved = []
    with locked(path + ".lock"):
        rows = load_history(path)
        for host in hosts:
            n = counts.get(host, 0)
            r = rows.get(host)
            if not n or r is None or r["confirmed"]:
                continue
            r["strikes"] = max(0, r["strikes"] - n)
            relieved.append(host)
            if r["strikes"] == 0:
                del rows[host]
        save_history(path, rows)
    return relieved


# --- job-scoped ledger -------------------------------------------------------


def ledger_path(statedir):
    return os.path.join(statedir, "ledger.jsonl") if statedir else None


def read_ledger(statedir):
    p = ledger_path(statedir)
    if not p or not os.path.exists(p):
        return []
    out = []
    for ln in read_lines(p):
        if ln.strip():
            with contextlib.suppress(json.JSONDecodeError):
                out.append(json.loads(ln))
    return out


def append_ledger(statedir, record):
    if not statedir:
        return
    os.makedirs(statedir, exist_ok=True)
    with locked(os.path.join(statedir, "ledger.lock")):
        with open(ledger_path(statedir), "a", encoding="utf-8") as f:
            f.write(json.dumps(record, sort_keys=True) + "\n")


def strikes_file(statedir):
    return os.path.join(statedir, "strikes_by_this_job.tsv") if statedir else None


def record_job_strike(statedir, host):
    if not statedir:
        return
    with locked(os.path.join(statedir, "strikes.lock")):
        counts = load_job_strikes(statedir)
        counts[host] = counts.get(host, 0) + 1
        write_atomic(strikes_file(statedir),
                     "".join(f"{h}\t{n}\n" for h, n in sorted(counts.items())))


def load_job_strikes(statedir):
    p = strikes_file(statedir)
    counts = {}
    if p and os.path.exists(p):
        for ln in read_lines(p):
            parts = ln.split("\t")
            if len(parts) == 2 and parts[1].strip().isdigit():
                counts[parts[0]] = int(parts[1])
    return counts


def clear_job_strikes(statedir, hosts):
    if not statedir:
        return
    with locked(os.path.join(statedir, "strikes.lock")):
        counts = load_job_strikes(statedir)
        for h in hosts:
            counts.pop(h, None)
        write_atomic(strikes_file(statedir),
                     "".join(f"{h}\t{n}\n" for h, n in sorted(counts.items())))


# --- suppressors -------------------------------------------------------------


def systematic_signature(ledger, phase, sig, this_host):
    """Same (phase, sig) already seen on other hosts ⇒ a software bug, not a node."""
    if sig is None:
        return None
    hosts = {this_host} if this_host else set()
    for rec in ledger:
        if rec.get("phase") == phase and rec.get("sig") == sig:
            hosts.update(rec.get("hosts", []))
    if len(hosts) >= systematic_min_hosts:
        return sorted(hosts)
    return None


def correlated_event(ledger, epoch, this_sim):
    """Several sims dying at once is a job-wide event, not N bad nodes."""
    sims = set() if this_sim is None else {this_sim}
    for rec in ledger:
        if abs(rec.get("epoch", 0) - epoch) <= correlated_window_s:
            if rec.get("sim") is not None:
                sims.add(rec["sim"])
    return sorted(sims) if len(sims) >= correlated_min_sims else None


# --- spare pool --------------------------------------------------------------


def claim_spares(pool, statedir, count, sim, dry_run):
    """Pop `count` hosts off the shared pool under a lock.  Returns [] if short."""
    # The lock belongs to the resource, not to the caller: sims may keep their
    # own state dirs but they all draw from the one pool.
    with locked(pool + ".lock"):
        spares = read_hosts(pool) if os.path.exists(pool) else []
        if len(spares) < count:
            return []
        taken, rest = spares[:count], spares[count:]
        if not dry_run:
            write_atomic(pool, "".join(h + "\n" for h in rest))
            if statedir:
                with open(os.path.join(statedir, "claimed.tsv"), "a",
                          encoding="utf-8") as f:
                    for h in taken:
                        f.write(f"{now_iso()}\t{sim}\t{h}\n")
        return taken


# --- subcommands -------------------------------------------------------------


def diagnose(args, record=True):
    """Returns (verdict, replace_hosts, strike_hosts, reasons, ev).

    verdict is 'replace' (swap these out), 'strike' (record only), 'none'
    (nothing blamed) or 'systematic' (a software signature — blame nobody, and
    do not even record a strike)."""
    hosts = read_hosts(args.hostfile) if args.hostfile else []
    lines = read_lines(args.log_slice)
    ev = parse_slice(lines, hosts, args.ranks_per_node)
    per_host = best_grade(ev.accusations)

    for host in list(per_host):
        if host in ev.exonerated:
            say(f"{host} exonerated by FSSTALL/MEMSTALL; dropping accusation")
            del per_host[host]

    if hosts:
        for host in list(per_host):
            if host not in hosts:
                say(f"{host} is not in this sim's hostfile; ignoring")
                del per_host[host]

    for host, (grade, kind, detail) in sorted(per_host.items()):
        say(f"accused {host} [{grade}] {kind}" + (f" ({detail})" if detail else ""))
    for host, rank, sig in ev.collateral:
        say(f"collateral: {host} rank {rank} torn down with sig {sig} — not blamed")

    if not per_host:
        say("no node blamed by this attempt's output")
        return "none", [], [], {}, ev

    ledger = read_ledger(args.statedir) if args.statedir else []
    epoch = int(dt.datetime.now(dt.timezone.utc).timestamp())

    accused_hosts = sorted(per_host)
    sig_host = next((h for h, v in per_host.items() if "app-signal" in v[1]), None)
    same = systematic_signature(ledger, ev.phase, ev.sig, sig_host)
    if same:
        say(f'systematic: sig {ev.sig} in phase "{ev.phase}" seen on '
            f"{len(same)} hosts ({', '.join(same)}) — a software signature, blaming nobody")
        if record:
            append_ledger(args.statedir, dict(
                epoch=epoch, sim=args.sim, attempt=getattr(args, "attempt", None),
                hosts=accused_hosts, kinds=[per_host[h][1] for h in accused_hosts],
                phase=ev.phase, sig=ev.sig, step=ev.last_step,
                verdict="systematic", replace=[]))
        return "systematic", [], [], {}, ev

    corr = correlated_event(ledger, epoch, args.sim)
    if corr:
        say(f"correlated: sims {corr} failed within {correlated_window_s}s — "
            "job-wide event, downgrading all accusations to strikes")
        for h in per_host:
            per_host[h] = ("strike",) + per_host[h][1:]

    history = load_history(history_path(args.history))
    replace, strike = [], []
    for host, (grade, kind, _detail) in sorted(per_host.items()):
        if grade == "high":
            replace.append(host)
        elif history.get(host, {}).get("strikes", 0) >= 1:
            say(f"{host} already carries "
                f"{history[host]['strikes']} strike(s) ({history[host]['reasons']}); "
                f"escalating {grade} to a replacement")
            replace.append(host)
        else:
            say(f"{host} takes a strike ({kind}); not replacing on first offence")
            strike.append(host)

    verdict = "replace" if replace else "strike"
    if record:
        append_ledger(args.statedir, dict(
            epoch=epoch, sim=args.sim, attempt=getattr(args, "attempt", None),
            hosts=accused_hosts, kinds=[per_host[h][1] for h in accused_hosts],
            phase=ev.phase, sig=ev.sig, step=ev.last_step, verdict=verdict,
            replace=replace))
    return verdict, replace, strike, {h: per_host[h][1] for h in per_host}, ev


def cmd_diagnose(args):
    verdict, replace, strike, _reasons, ev = diagnose(args, record=False)
    say(f"verdict={verdict} last_step={ev.last_step} "
        f"replace={','.join(replace) or '-'} strike={','.join(strike) or '-'}")
    return 0 if verdict == "replace" else 1


def cmd_replace(args):
    if not args.hostfile:
        say("replace needs --hostfile: the spare has to go somewhere")
        return 3
    if not os.path.exists(args.log_slice) or os.path.getsize(args.log_slice) == 0:
        say("empty log slice; nothing to diagnose")
        return 1

    _verdict, replace, strike, reasons, _ev = diagnose(args, record=not args.dry_run)
    hist = history_path(args.history)

    if not args.dry_run:
        for host in strike:
            bump_history(hist, host, reasons.get(host, "unknown"), confirmed=False)
            record_job_strike(args.statedir, host)
        # Record the confirmed-bad hosts before trying to claim a spare: even if
        # the pool is empty and this sim dies, the next job must quarantine them.
        for host in replace:
            bump_history(hist, host, reasons.get(host, "unknown"), confirmed=True)

    if not replace:
        return 1

    spares = claim_spares(args.pool, args.statedir, len(replace), args.sim,
                          args.dry_run)
    if not spares:
        say(f"blaming {', '.join(replace)} but the spare pool has no "
            f"{len(replace)} node(s) left; giving up on this sim")
        return 2

    # Substitute in place so the line order — and therefore which node hosts
    # rank 0 — changes as little as possible.
    hosts = read_hosts(args.hostfile)
    swap = dict(zip(replace, spares))
    new = [swap.get(h, h) for h in hosts]
    if len(new) != len(hosts):
        say("refusing to change the node count; NNODES feeds -np 2*NNODES")
        return 3

    for host in replace:
        say(f"replacing {host} with {swap[host]}")

    if args.dry_run:
        say(f"dry run: would write {args.out}")
    else:
        write_atomic(args.out, "".join(h + "\n" for h in new))
        say(f"wrote {args.out} ({len(new)} nodes)")
    return 0


def cmd_absolve(args):
    hosts = read_hosts(args.hostfile)
    counts = load_job_strikes(args.statedir)
    relieved = relieve_history(history_path(args.history), hosts, counts)
    clear_job_strikes(args.statedir, hosts)
    if relieved:
        say(f"absolved {', '.join(relieved)} after a healthy run")
    return 0


def cmd_order_nodes(args):
    """Split a nodefile into nodes fit to assign and nodes to hold back."""
    nodes = read_hosts(args.nodes)
    history = load_history(history_path(args.history))

    def badness(h):
        r = history.get(h)
        if not r:
            return 0
        return r["strikes"] + 100 * r["confirmed"]

    bad = [h for h in nodes if badness(h) >= quarantine_strikes]
    good = [h for h in nodes if h not in set(bad)]

    # Never quarantine so many that the sims cannot be placed: restore the
    # least-bad until we have enough.
    if args.required and len(good) < args.required:
        bad.sort(key=badness)
        while bad and len(good) < args.required:
            h = bad.pop(0)
            good.append(h)
            say(f"un-quarantining {h}: too few healthy nodes to place all sims")
        good = [h for h in nodes if h in set(good)]  # restore original order

    write_atomic(args.good, "".join(h + "\n" for h in good))
    write_atomic(args.quarantine, "".join(h + "\n" for h in bad))
    if bad:
        say(f"quarantined {len(bad)} known-bad node(s): {', '.join(bad)}")
    return 0


# --- entry point -------------------------------------------------------------


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    def add_diag_args(sp):
        sp.add_argument("--log-slice", required=True,
                        help="this attempt's slice of sim_<i>.out")
        sp.add_argument("--hostfile", help="this sim's current hostfile")
        sp.add_argument("--statedir", help="job-scoped state dir (ledger, locks)")
        sp.add_argument("--history", help="persistent TSV; else $ABACUS_NODEHEALTH")
        sp.add_argument("--sim", type=int, help="sim index, for the ledger")
        sp.add_argument("--ranks-per-node", type=int, default=2,
                        help="matches -ppn in aurora.def's mpirun_cmd (default 2)")

    sp = sub.add_parser("replace", help="diagnose, claim a spare, rewrite the hostfile")
    add_diag_args(sp)
    sp.add_argument("--pool", required=True, help="shared spare pool ($HOSTFILE_EXTRA)")
    sp.add_argument("--out", required=True, help="hostfile to write on success")
    sp.add_argument("--attempt", type=int)
    sp.add_argument("--dry-run", action="store_true")
    sp.set_defaults(func=cmd_replace)

    sp = sub.add_parser("diagnose", help="report only; writes no state")
    add_diag_args(sp)
    sp.set_defaults(func=cmd_diagnose)

    sp = sub.add_parser("absolve", help="undo this job's strikes after a healthy run")
    sp.add_argument("--hostfile", required=True)
    sp.add_argument("--statedir", required=True)
    sp.add_argument("--history")
    sp.set_defaults(func=cmd_absolve)

    sp = sub.add_parser("order-nodes", help="split a nodefile into usable/quarantined")
    sp.add_argument("--nodes", required=True)
    sp.add_argument("--good", required=True)
    sp.add_argument("--quarantine", required=True)
    sp.add_argument("--history")
    sp.add_argument("--required", type=int, default=0,
                    help="nodes the sims must have; caps how many we hold back")
    sp.set_defaults(func=cmd_order_nodes)

    args = p.parse_args(argv)
    if getattr(args, "statedir", None):
        os.makedirs(args.statedir, exist_ok=True)
    try:
        return args.func(args)
    except Exception as e:  # never let a diagnosis bug take down a sim
        say(f"internal error ({type(e).__name__}: {e}); caller should carry on")
        return 3


if __name__ == "__main__":
    sys.exit(main())
