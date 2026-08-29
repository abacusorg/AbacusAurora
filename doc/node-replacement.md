# Replacing nodes that kill a sim

When a sim dies, `onesim.sh` relaunches it. Until now it relaunched on **the same
hostfile**, including whichever node had just killed it — so a node-caused failure spent
the entire restart budget re-running onto a corpse. This document describes the machinery
that decides whether a node is actually to blame, swaps it for a spare, and — just as
importantly — declines to blame anyone when the evidence says the fault is in the code.

The pieces:

| where | what it does |
|---|---|
| `hashrun.sh -x N` | asks PBS for `N` nodes beyond what the sims need |
| `multisim.pbs` | holds back nodes with a bad history, slices the rest, and puts the surplus in `$HOSTFILE_EXTRA` |
| `onesim.sh` | after a failure, hands that attempt's output to `nodehealth.py` and relaunches on whatever hostfile comes back |
| `job/nodehealth.py` | reads the log, grades the accusations, claims a spare under a lock, rewrites the hostfile |

## What the logs actually say

Nothing here invents a vocabulary. The Abacus C++ already emits machine-greppable stderr
markers designed for exactly this — see `src/include/node_diag_logging.h` in the code
repo, whose header spells out what each one licenses a launcher to do. PALS adds its own
death messages. `multisim.pbs` merges stdout and stderr into `sim_<i>.out`, so everything
lands in one file.

| line | who says it | what it means |
|---|---|---|
| `<h>: shepherd died from signal 9` | PALS | the per-node shepherd was SIGKILLed. This is the *initiating* death |
| `<h>: rank N died from signal 15` | PALS | the launcher tearing down everyone else afterwards. **Collateral** |
| `ping RPC timeout from <h> after 120s` | PALS | `palsd` stopped getting answers; the node went silent |
| `NODEFAIL … op="signal" sig=11` | `crash_handler.h` | a rank took SIGSEGV/SIGBUS/SIGFPE and printed a backtrace |
| `NODEFAIL … op="gpu …"` / `op="NumaAlloc …"` | `GPUControl.sycl.cpp`, `numa_alloc.cpp` | a device or memory operation failed outright |
| `NODEFAIL … peerhost=<p>` | `ParallelConvolution.cpp` | this rank gave up waiting on `<p>` |
| `NODEWARN …` | same watchdog | still waiting, may yet recover |
| `FSSTALL …` / `MEMSTALL …` | `fsstall_watch.h`, `memstall_watch.h` | this host is blocked on the filesystem or on memory, not broken |
| `RANK_IS_HEALTHY …` | `multistep.cpp` | a startup beacon, one per rank |

Two of these are traps. The `signal 15` line names a **different host** from the `signal 9`
line in every failure we have, and blaming it would retire a healthy node every time.
`NODEWARN` looks like an accusation and is explicitly documented as not being one.

## Grading

Accusations carry a grade, and only the top one acts immediately.

**`high` — replace now.** Shepherd SIGKILL; ping timeout; `op="gpu …"` or
`op="NumaAlloc …"`; two or more ranks naming the same `peerhost=`; or, during startup, a
single hostfile node that never printed `RANK_IS_HEALTHY` while its neighbours did.

**`medium` — replace on a repeat.** A rank dying from a signal other than 15 or 9; a ring
probe naming an unresponsive peer; any other `NODEFAIL` against a host.

**`strike` — record only.** An Abacus fatal signal (`op="signal"`). The host has to
already be carrying a strike before this escalates to a replacement.

**Never.** `NODEWARN`; the SIGTERM'd rank of a teardown; `QUIT` and failed assertions,
which name a host but are deliberately not `NODEFAIL`s.

**Exoneration.** An `FSSTALL` or `MEMSTALL` from a host cancels accusations against it.
A node blocked on a slow filesystem read looks exactly like a dead one to its peers, and
this is the designed correction — it is how the 2026-08-02 flare stall was diagnosed
without anyone blaming `x4504c5s1b0n0`.

Where a line names only a rank, it is resolved through the hostfile: `aurora.def` runs
`-ppn 2 -np 2*NNODES`, so rank *r* is on hostfile line `r//2 + 1`.

## Declining to blame

Two suppressors sit above the grading, and they are the reason this is safe to leave
running unattended.

**Systematic signature.** Every failure appends to a job-wide ledger. If the same
`(phase, sig)` has now been seen on two or more *different* hosts, the conclusion is a
software bug and nobody is blamed — not even a strike.

**Correlated job event.** If three or more sims fail within 180 s of one another, every
accusation in that window is downgraded to a strike. A fabric hiccup or a PBS escalation
must not be allowed to retire a dozen good nodes at once.

Blame also decays. Unconfirmed strikes older than 14 days are forgotten, and any attempt
that runs longer than `min_healthy_seconds`, or exits clean, calls `absolve` to clear the
strikes this job put on the nodes still in its hostfile. A node present at a late,
recoverable failure therefore never accumulates blame it did not earn.

## Reading the crashes this was built from

Seven failures from jobs 8766714, 8766809, 8778470 and 8778478 are checked in as fixtures
under `job/test/nodehealth/`. They are worth understanding, because the step at which a
sim dies says more than the signal does.

A `status.log` row is written at the *end* of a step, so the last row tells you which step
completed, and the crash is in the step after it.

**Died in step 1** (last row: step 0) — `8766809_sim_9`, `8766809_sim_21`,
`8778478_sim_1`, all `sig=11`. Step 0 does not use the GPUs; its rate is 12.5 Mp/s against
73 Mp/s for step 1. So step 1 is the first time a large dataset is pushed to the device,
and the backtraces implicate the copy-to-GPU path. The host-side HBM is already faulted by
then; the suspicion is device-side allocation, which the pre-step-0 health check is not
tripping. Three different hosts, two jobs, same phase — a code or driver problem, not bad
hardware. These take a strike and the sim relaunches unchanged; once two are in the ledger
the systematic suppressor stops even that.

**Died in step 3** (last row: step 2) — `8766714_sim_2`, `8766714_sim_6`. Step 3 is the
first non-LPT step. These are the genuinely puzzling ones: no Abacus marker at all, just a
shepherd SIGKILL, which is graded `high` and replaces the node.

**Died in step 1** (last row: step 0) — `8766714_sim_14`, the same shepherd signature
but much earlier in the run.

**A ping timeout** — `8778470_sim_5`. The excerpt collected is the launcher's line
alone, with no step table, so which step it was in is not recorded here; it does not
matter. A node that had been answering stopped answering, and that reading is the same
whenever it happens.

### A gap this exposes

The systematic suppressor keys on the `phase` and `sig` fields of a `NODEFAIL`. A PALS
shepherd death carries neither, so a cluster of shepherd SIGKILLs at the same step
boundary — which is what `8766714_sim_2` and `sim_6` look like — is invisible to it, and
each one replaces a node. If those turn out to be the workload rather than the hardware
(the step-3 allocation peak against an `MxRSS` already at 294–299 GiB is the obvious
suspect), the replacements will not help and the spare pool will drain. The ledger already
records the step of every failure, so extending the suppressor to fire on a repeated
`(class, step)` across hosts would close it. Not done yet — flagged here so the first time
it bites, it is recognised rather than rediscovered.

## How it works mechanically

**Per-attempt log window.** `onesim.sh` records `wc -c` of `$ABACUS_SIM_LOG` after
printing its invocation banner, and after the attempt slices from there with `tail -c +N`.
So each diagnosis sees exactly one attempt's output, never a previous attempt's
accusations. This is deliberately not a `tee` pipeline: that would put a pipe between
`abacus.run` and its output fd, and PALS and dfuse behaviour there is not worth
disturbing. `nodehealth.py` prefixes every line it prints with `# nodehealth:` so its own
report can never be re-read as a marker.

**The lock.** Every `onesim.sh` is a background child of one `multisim.pbs` on a single
node, so a plain `flock` is enough; there is no distributed locking anywhere here. The
lock is keyed to the pool file itself, so sims keeping separate state dirs still exclude
one another. Claiming is pop-and-rewrite under the lock, published with `os.replace`.

**The rewrite.** The blamed host is substituted **in place**, preserving line order, so
rank 0 keeps its line unless rank 0's node is the one being replaced. The line count never
changes — `NNODES` feeds `-np 2*NNODES`, and a hostfile of a different length would
silently change the decomposition. The result is written as `nodefile_part_NNN.a<attempt>`;
the original is left alone for provenance.

**The budget.** A replacement does not count as a rapid consecutive failure — the cause
was external and has been removed — and it buys back one restart, up to
`max_replacements=4`. If a node is blamed and the pool is empty, the sim exits nonzero
immediately rather than spending attempts on a node believed dead.

**State**, all under `job/out/<jobid>/`:

```text
hostfile_extra              the spare pool, shrinking as spares are claimed
hostfile_quarantine         nodes held back at the start for a bad history
nodes.usable                the allocation minus the quarantine, in original order
nodefile_part_NNN[.aK]      each sim's hostfile, one file per revision
nodehealth/ledger.jsonl     every failure: hosts, kinds, phase, sig, step, verdict
nodehealth/claimed.tsv      which sim took which spare, and when
nodehealth/simN.attemptK.log  the slice that was diagnosed
```

The cross-job history is `job/out/nodehealth.tsv` (override with `$ABACUS_NODEHEALTH`):
host, strikes, confirmed, first seen, last seen, reasons. `job/out/` is git-ignored, so
none of this dirties the tree that `hashrun.sh` insists is clean. A node with two strikes,
or one confirmed replacement, is quarantined by the next job — unless quarantining it
would leave too few nodes to place all the sims, in which case the least-bad are restored
and a warning is printed.

## Operating it

Ask for spares when you submit. These are equivalent:

```
./hashrun.sh -nps 8 -x 4 -t 02:00 b346251 in/list1
```

`-x` is sugar over `-n`: for an eight-sim list the line above is `-n 68`, i.e.
`8 x 8 + 4`. The two cannot be combined, since both set the total.

With no spares the machinery still runs and still records history; it simply has nothing
to swap in, so a blamed node ends that sim.

What to look for afterwards. In `sim_<i>.out`:

```
# nodehealth: accused x4117c0s6b0n0 [high] shepherd-killed (shepherd SIGKILL)
# nodehealth: collateral: x4115c5s4b0n0 rank 12 torn down with sig 15 — not blamed
# nodehealth: replacing x4117c0s6b0n0 with x8888c0s0b0n0
```

and in the job's stdout, the allocation line now reports the quarantine:

```
Allocation: 8 sim(s) x 8 node(s) = 64 used; 3 spare; 1 quarantined
```

Curating the history is a matter of editing `job/out/nodehealth.tsv` — deleting a row
forgives a node, and setting `confirmed` to 1 quarantines it from the next job onwards.
Nodes with a confirmed entry are worth reporting to ALCF with the jobid, node and
timestamp from the ledger.

To ask what the rules make of a log without changing anything:

```
python3 job/nodehealth.py diagnose --log-slice <some sim_N.out> --hostfile <its hostfile>
```

`diagnose` writes no state at all, so it is safe against anything.

## Testing

Two suites, neither needing Aurora, PBS, MPI or a built Abacus. Run both after touching
any of this:

```
python3 job/test/nodehealth/test_nodehealth.py     # the rules, against the seven fixtures
bash    job/test/nodehealth/test_onesim.sh         # the shell wiring, with a stub python
```

When a new signature turns up, drop the relevant lines of `sim_<i>.out` into
`job/test/nodehealth/` as `<jobid>_sim_<i>.log` and add a case. See the README there.

## What this cannot do

If a node failure takes the **whole PBS job** down, no amount of hostfile surgery inside
the job helps; the persistent history is the only lever, and it acts on the next
submission.

It cannot diagnose a **hang**. Abacus installs handlers for SIGSEGV, SIGBUS and SIGFPE but
not SIGTERM, so when the Python `StepTimeout` watchdog kills a wedged run, no rank reports
where it was. Adding a SIGTERM handler would make every rank print its `phase`, and is the
single highest-value change available to this machinery.

It has no per-step, per-rank view of node health. `step####.time.bin` already carries a
`PerformanceSummary` for every rank but no hostname field; adding one would give a
rank→host map for free and let a degrading node be spotted before it kills anything.
